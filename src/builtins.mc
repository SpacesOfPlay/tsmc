// builtins.mc — the standard library surface.
//
// builtins_install runs after vm_init: creates the well-known
// prototypes, wires the constructors, registers natives. Natives
// root intermediate GC values on the heap's root stack (mark/reset)
// or by storing them into an already-rooted container immediately
// after allocation.

import vec;
import str;
import map;
import value;
import gc;
import atom;
import object;
import ustr;
import vm;
import math;

// Platform math not covered by the math module: hyperbolic functions
// and the accurate log1p/expm1, used by the extra Math.* methods.
when os(windows) {
    extern "ucrtbase.dll" f64 sinh(f64 x);
    extern "ucrtbase.dll" f64 cosh(f64 x);
    extern "ucrtbase.dll" f64 tanh(f64 x);
    extern "ucrtbase.dll" f64 asinh(f64 x);
    extern "ucrtbase.dll" f64 acosh(f64 x);
    extern "ucrtbase.dll" f64 atanh(f64 x);
    extern "ucrtbase.dll" f64 log1p(f64 x);
    extern "ucrtbase.dll" f64 expm1(f64 x);
}
when os(linux) {
    extern "libm.so.6" f64 sinh(f64 x);
    extern "libm.so.6" f64 cosh(f64 x);
    extern "libm.so.6" f64 tanh(f64 x);
    extern "libm.so.6" f64 asinh(f64 x);
    extern "libm.so.6" f64 acosh(f64 x);
    extern "libm.so.6" f64 atanh(f64 x);
    extern "libm.so.6" f64 log1p(f64 x);
    extern "libm.so.6" f64 expm1(f64 x);
}
when os(android) {
    extern "libm.so" f64 sinh(f64 x);
    extern "libm.so" f64 cosh(f64 x);
    extern "libm.so" f64 tanh(f64 x);
    extern "libm.so" f64 asinh(f64 x);
    extern "libm.so" f64 acosh(f64 x);
    extern "libm.so" f64 atanh(f64 x);
    extern "libm.so" f64 log1p(f64 x);
    extern "libm.so" f64 expm1(f64 x);
}
when os(macos) || os(ios) {
    extern "libSystem.B.dylib" f64 sinh(f64 x);
    extern "libSystem.B.dylib" f64 cosh(f64 x);
    extern "libSystem.B.dylib" f64 tanh(f64 x);
    extern "libSystem.B.dylib" f64 asinh(f64 x);
    extern "libSystem.B.dylib" f64 acosh(f64 x);
    extern "libSystem.B.dylib" f64 atanh(f64 x);
    extern "libSystem.B.dylib" f64 log1p(f64 x);
    extern "libSystem.B.dylib" f64 expm1(f64 x);
}

private VM* as_vm(void* p) {
    return cast(VM*, p);
}

private bool bi_nullish(Value v) {
    return value_is_null(v) || value_is_undefined(v);
}

private Value arg_at(Value* args, i32 argc, i32 i) {
    if i < argc { return *(args + i); }
    return value_undefined();
}

private str sview(Value v) {
    return gc_string_view(value_as_string(v));
}

private Value new_str(VM* vm, str s) {
    GcString* g = gc_new_string(&vm.heap, s);
    return value_cell(&g.head);
}

private i32 to_int_arg(Value v) {
    f64 d = js_to_number(v);
    if d != d { return 0; }
    return cast(i32, cast(i64, d));
}

private u32 bi_atom(VM* vm, str name) {
    return atom_intern(&vm.atoms, name);
}

private i32 bi_utf8_encode(u8* dst, u32 cp) {
    if cp < 0x80 {
        *dst = cast(u8, cp);
        return 1;
    }
    if cp < 0x800 {
        *dst = cast(u8, 0xC0 | (cp >> 6));
        *(dst + 1) = cast(u8, 0x80 | (cp & 0x3F));
        return 2;
    }
    if cp < 0x10000 {
        *dst = cast(u8, 0xE0 | (cp >> 12));
        *(dst + 1) = cast(u8, 0x80 | ((cp >> 6) & 0x3F));
        *(dst + 2) = cast(u8, 0x80 | (cp & 0x3F));
        return 3;
    }
    *dst = cast(u8, 0xF0 | (cp >> 18));
    *(dst + 1) = cast(u8, 0x80 | ((cp >> 12) & 0x3F));
    *(dst + 2) = cast(u8, 0x80 | ((cp >> 6) & 0x3F));
    *(dst + 3) = cast(u8, 0x80 | (cp & 0x3F));
    return 4;
}

// --- Object ---------------------------------------------------------------

private Value nat_object_ctor(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    Value v = arg_at(args, argc, 0);
    if value_is_object(v) { return v; }
    JsObject* o = js_new_object(&vm.heap, vm.object_proto);
    return value_cell(&o.head);
}

private Value nat_object_keys(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    JsObject* arr = vm_own_keys(vm, arg_at(args, argc, 0));
    return value_cell(&arr.head);
}

private Value nat_object_values(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    JsObject* arr = js_new_array(&vm.heap, vm.array_proto);
    i32 rm = gc_root_mark(&vm.heap);
    gc_root(&vm.heap, value_cell(&arr.head));
    Value ov = arg_at(args, argc, 0);
    if value_is_object(ov) {
        JsObject* o = value_as_object(ov);
        i32 n = 0;
        if (o.obj_flags & OBJF_ARRAY) != 0 {
            for i32 i = 0; i < o.elen; i++ {
                if !js_array_has(o, i) { continue; }
                js_array_set(arr, n, js_array_get(o, i));
                n++;
            }
        }
        for i32 i = 0; i < o.props.len; i++ {
            if !prop_enumerable(vm, o.props.items + i) { continue; }
            Value pv = (o.props.items + i).val;
            if value_is_accessor(pv) {
                if !vm_get_prop_value(vm, ov, (o.props.items + i).key, &pv) {
                    gc_root_reset(&vm.heap, rm);
                    return value_undefined();
                }
            }
            js_array_set(arr, n, pv);
            n++;
        }
    }
    gc_root_reset(&vm.heap, rm);
    return value_cell(&arr.head);
}

private Value nat_object_entries(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    JsObject* arr = js_new_array(&vm.heap, vm.array_proto);
    i32 rm = gc_root_mark(&vm.heap);
    gc_root(&vm.heap, value_cell(&arr.head));
    Value ov = arg_at(args, argc, 0);
    if value_is_object(ov) {
        JsObject* o = value_as_object(ov);
        i32 n = 0;
        if (o.obj_flags & OBJF_ARRAY) != 0 {
            for i32 i = 0; i < o.elen; i++ {
                if !js_array_has(o, i) { continue; }
                JsObject* pair = js_new_array(&vm.heap, vm.array_proto);
                js_array_set(arr, n, value_cell(&pair.head));
                string s = format("{}", i);
                Value ks = new_str(vm, s);
                free(s);
                js_array_set(pair, 0, ks);
                js_array_set(pair, 1, js_array_get(o, i));
                n++;
            }
        }
        for i32 i = 0; i < o.props.len; i++ {
            if !prop_enumerable(vm, o.props.items + i) { continue; }
            u32 pk = (o.props.items + i).key;
            Value pv = (o.props.items + i).val;
            if value_is_accessor(pv) {
                if !vm_get_prop_value(vm, ov, pk, &pv) {
                    gc_root_reset(&vm.heap, rm);
                    return value_undefined();
                }
            }
            JsObject* pair = js_new_array(&vm.heap, vm.array_proto);
            js_array_set(arr, n, value_cell(&pair.head));
            Value ks = new_str(vm, atom_name(&vm.atoms, pk));
            js_array_set(pair, 0, ks);
            js_array_set(pair, 1, pv);
            n++;
        }
    }
    gc_root_reset(&vm.heap, rm);
    return value_cell(&arr.head);
}

private Value nat_object_assign(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    Value tv = arg_at(args, argc, 0);
    if !value_is_object(tv) {
        vm_throw_error(vm, ERR_TYPE, "Object.assign target must be an object");
        return value_undefined();
    }
    JsObject* t = value_as_object(tv);
    for i32 s = 1; s < argc; s++ {
        Value sv2 = *(args + s);
        if !value_is_object(sv2) { continue; }
        JsObject* src = value_as_object(sv2);
        if src == t { continue; }
        if (src.obj_flags & OBJF_ARRAY) != 0 && (t.obj_flags & OBJF_ARRAY) != 0 {
            for i32 i = 0; i < src.elen; i++ {
                js_array_set(t, i, js_array_get(src, i));
            }
        }
        for i32 i = 0; i < src.props.len; i++ {
            if !prop_enumerable(vm, src.props.items + i) { continue; }
            u32 pk = (src.props.items + i).key;
            Value pv = (src.props.items + i).val;
            if value_is_accessor(pv) {
                if !vm_get_prop_value(vm, sv2, pk, &pv) { return value_undefined(); }
            }
            js_set_prop(t, pk, pv);
        }
    }
    return tv;
}

private Value nat_object_create(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    Value pv = arg_at(args, argc, 0);
    JsObject* proto = null;
    if value_is_object(pv) { proto = value_as_object(pv); }
    JsObject* o = js_new_object(&vm.heap, proto);
    return value_cell(&o.head);
}

private Value nat_object_getproto(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    Value ov = arg_at(args, argc, 0);
    if value_is_object(ov) {
        JsObject* p = value_as_object(ov).proto;
        if p != null { return value_cell(&p.head); }
    } else if value_is_function(ov) {
        // derived-class ctor -> parent ctor; else Function.prototype
        Value fp = value_as_function(ov).fproto;
        if value_is_function(fp) || value_is_native(fp) { return fp; }
        if vm.function_proto != null { return value_cell(&vm.function_proto.head); }
    } else if value_is_native(ov) {
        if vm.function_proto != null { return value_cell(&vm.function_proto.head); }
    }
    return value_null();
}

// All own string-keyed property names, enumerable or not (arrays add
// their indices and "length").
private Value nat_object_getownnames(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    JsObject* arr = js_new_array(&vm.heap, vm.array_proto);
    i32 rm = gc_root_mark(&vm.heap);
    gc_root(&vm.heap, value_cell(&arr.head));
    Value ov = arg_at(args, argc, 0);
    if value_is_object(ov) {
        JsObject* o = value_as_object(ov);
        i32 n = 0;
        if (o.obj_flags & OBJF_ARRAY) != 0 {
            for i32 i = 0; i < o.elen; i++ {
                if !js_array_has(o, i) { continue; }
                string s = format("{}", i);
                Value ks = new_str(vm, s);
                free(s);
                js_array_set(arr, n, ks);
                n++;
            }
        }
        for i32 i = 0; i < o.props.len; i++ {
            u32 key = (o.props.items + i).key;
            if (key & 0x80000000) != 0 { continue; }
            js_array_set(arr, n, new_str(vm, atom_name(&vm.atoms, key)));
            n++;
        }
        if (o.obj_flags & OBJF_ARRAY) != 0 {
            js_array_set(arr, n, new_str(vm, "length"));
        }
    }
    gc_root_reset(&vm.heap, rm);
    return value_cell(&arr.head);
}

private Value nat_object_setproto(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    Value ov = arg_at(args, argc, 0);
    Value pv = arg_at(args, argc, 1);
    if value_is_object(ov) {
        JsObject* o = value_as_object(ov);
        if value_is_object(pv) {
            o.proto = value_as_object(pv);
        } else if value_is_null(pv) {
            o.proto = null;
        }
    }
    return ov;
}

// True if ov has an own or inherited property named `name`.
private bool desc_has(VM* vm, Value ov, str name) {
    if !value_is_object(ov) { return false; }
    u32 a = atom_intern(&vm.atoms, name);
    JsObject* o = value_as_object(ov);
    while o != null {
        if props_entry(&o.props, a) != null { return true; }
        o = o.proto;
    }
    return false;
}

private Value nat_object_defineproperty(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    Value ov = arg_at(args, argc, 0);
    if !value_is_object(ov) {
        vm_throw_error(vm, ERR_TYPE, "Object.defineProperty called on non-object");
        return value_undefined();
    }
    JsObject* o = value_as_object(ov);
    i32 rm = gc_root_mark(&vm.heap);
    Value kv = js_to_string_value(vm, arg_at(args, argc, 1));
    gc_root(&vm.heap, kv);
    u32 key = atom_intern(&vm.atoms, sview(kv));
    Value desc = arg_at(args, argc, 2);
    if !value_is_object(desc) {
        gc_root_reset(&vm.heap, rm);
        vm_throw_error(vm, ERR_TYPE, "property description must be an object");
        return value_undefined();
    }

    // start from the existing attributes, or all-false for a new property
    Prop* existing = props_entry(&o.props, key);
    u8 flags = existing != null ? existing.flags : 0;

    Value tmp;
    if desc_has(vm, desc, "enumerable") {
        ignore vm_get_prop_value(vm, desc, bi_atom(vm, "enumerable"), &tmp);
        if js_truthy(tmp) { flags = flags | PROP_ENUMERABLE; }
        else { flags = flags & cast(u8, ~PROP_ENUMERABLE); }
    }
    if desc_has(vm, desc, "configurable") {
        ignore vm_get_prop_value(vm, desc, bi_atom(vm, "configurable"), &tmp);
        if js_truthy(tmp) { flags = flags | PROP_CONFIGURABLE; }
        else { flags = flags & cast(u8, ~PROP_CONFIGURABLE); }
    }

    Value stored;
    if desc_has(vm, desc, "get") || desc_has(vm, desc, "set") {
        Value g = value_undefined();
        Value s = value_undefined();
        if desc_has(vm, desc, "get") { ignore vm_get_prop_value(vm, desc, bi_atom(vm, "get"), &g); }
        if desc_has(vm, desc, "set") { ignore vm_get_prop_value(vm, desc, bi_atom(vm, "set"), &s); }
        JsAccessor* ac = js_new_accessor(&vm.heap);
        ac.get = value_is_callable(g) ? g : value_undefined();
        ac.set = value_is_callable(s) ? s : value_undefined();
        stored = value_cell(&ac.head);
        flags = flags & cast(u8, ~PROP_WRITABLE);
    } else {
        Value val = value_undefined();
        if existing != null && !value_is_accessor(existing.val) { val = existing.val; }
        if desc_has(vm, desc, "value") { ignore vm_get_prop_value(vm, desc, bi_atom(vm, "value"), &val); }
        if desc_has(vm, desc, "writable") {
            ignore vm_get_prop_value(vm, desc, bi_atom(vm, "writable"), &tmp);
            if js_truthy(tmp) { flags = flags | PROP_WRITABLE; }
            else { flags = flags & cast(u8, ~PROP_WRITABLE); }
        }
        stored = val;
    }
    props_set_desc(&o.props, key, stored, flags);
    gc_root_reset(&vm.heap, rm);
    return ov;
}

private Value nat_object_defineproperties(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    Value ov = arg_at(args, argc, 0);
    Value props = arg_at(args, argc, 1);
    if !value_is_object(ov) || !value_is_object(props) { return ov; }
    JsObject* p = value_as_object(props);
    // snapshot keys first; defining may reallocate the source table
    i32 n = p.props.len;
    for i32 i = 0; i < n; i++ {
        Prop* pr = p.props.items + i;
        if !prop_enumerable(vm, pr) { continue; }
        u32 key = pr.key;
        Value d;
        if !vm_get_prop_value(vm, props, key, &d) { return value_undefined(); }
        i32 rm = gc_root_mark(&vm.heap);
        gc_root(&vm.heap, d);
        Value kstr = new_str(vm, atom_name(&vm.atoms, key));
        Value[3] a2 = { ov, kstr, d };
        ignore nat_object_defineproperty(vmp, callee, value_undefined(), &a2[0], 3);
        gc_root_reset(&vm.heap, rm);
        if vm.has_pending { return value_undefined(); }
    }
    return ov;
}

private Value nat_object_getownpropdesc(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    Value ov = arg_at(args, argc, 0);
    if !value_is_object(ov) { return value_undefined(); }
    JsObject* o = value_as_object(ov);
    i32 rm = gc_root_mark(&vm.heap);
    Value kv = js_to_string_value(vm, arg_at(args, argc, 1));
    gc_root(&vm.heap, kv);
    str kname = sview(kv);
    u32 key = atom_intern(&vm.atoms, kname);

    // array index / length live outside the property table
    if (o.obj_flags & OBJF_ARRAY) != 0 {
        bool is_len = str_equal(kname, "length");
        i32 idx = -1;
        if !is_len {
            f64 nv = js_to_number(kv);
            i32 ni = cast(i32, nv);
            if cast(f64, ni) == nv && ni >= 0 && ni < o.elen { idx = ni; }
        }
        if is_len || idx >= 0 {
            JsObject* d = js_new_object(&vm.heap, vm.object_proto);
            gc_root(&vm.heap, value_cell(&d.head));
            Value dv = is_len ? value_int(o.elen) : js_array_get(o, idx);
            js_set_prop(d, bi_atom(vm, "value"), dv);
            js_set_prop(d, bi_atom(vm, "writable"), value_bool(true));
            js_set_prop(d, bi_atom(vm, "enumerable"), value_bool(!is_len));
            js_set_prop(d, bi_atom(vm, "configurable"), value_bool(!is_len));
            gc_root_reset(&vm.heap, rm);
            return value_cell(&d.head);
        }
    }

    Prop* pe = props_entry(&o.props, key);
    if pe == null {
        gc_root_reset(&vm.heap, rm);
        return value_undefined();
    }
    JsObject* d = js_new_object(&vm.heap, vm.object_proto);
    gc_root(&vm.heap, value_cell(&d.head));
    if value_is_accessor(pe.val) {
        JsAccessor* ac = value_as_accessor(pe.val);
        js_set_prop(d, bi_atom(vm, "get"), ac.get);
        js_set_prop(d, bi_atom(vm, "set"), ac.set);
    } else {
        js_set_prop(d, bi_atom(vm, "value"), pe.val);
        js_set_prop(d, bi_atom(vm, "writable"), value_bool((pe.flags & PROP_WRITABLE) != 0));
    }
    js_set_prop(d, bi_atom(vm, "enumerable"), value_bool((pe.flags & PROP_ENUMERABLE) != 0));
    js_set_prop(d, bi_atom(vm, "configurable"), value_bool((pe.flags & PROP_CONFIGURABLE) != 0));
    gc_root_reset(&vm.heap, rm);
    return value_cell(&d.head);
}

// Clears the given attribute bits from every own property.
private void object_lock_props(JsObject* o, u8 clear) {
    for i32 i = 0; i < o.props.len; i++ {
        Prop* pr = o.props.items + i;
        pr.flags = pr.flags & cast(u8, ~clear);
    }
}

private Value nat_object_freeze(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    Value ov = arg_at(args, argc, 0);
    if value_is_object(ov) {
        JsObject* o = value_as_object(ov);
        object_lock_props(o, PROP_WRITABLE | PROP_CONFIGURABLE);
        o.obj_flags = o.obj_flags | OBJF_NONEXT;
    }
    return ov;
}

private Value nat_object_seal(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    Value ov = arg_at(args, argc, 0);
    if value_is_object(ov) {
        JsObject* o = value_as_object(ov);
        object_lock_props(o, PROP_CONFIGURABLE);
        o.obj_flags = o.obj_flags | OBJF_NONEXT;
    }
    return ov;
}

private Value nat_object_preventext(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    Value ov = arg_at(args, argc, 0);
    if value_is_object(ov) {
        JsObject* o = value_as_object(ov);
        o.obj_flags = o.obj_flags | OBJF_NONEXT;
    }
    return ov;
}

// All own data properties satisfy a predicate over cleared bits.
private bool object_all_locked(JsObject* o, u8 need_clear) {
    for i32 i = 0; i < o.props.len; i++ {
        if ((o.props.items + i).flags & need_clear) != 0 { return false; }
    }
    return true;
}

private Value nat_object_isfrozen(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    Value ov = arg_at(args, argc, 0);
    if !value_is_object(ov) { return value_bool(true); }
    JsObject* o = value_as_object(ov);
    if (o.obj_flags & OBJF_NONEXT) == 0 { return value_bool(false); }
    return value_bool(object_all_locked(o, PROP_WRITABLE | PROP_CONFIGURABLE));
}

private Value nat_object_issealed(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    Value ov = arg_at(args, argc, 0);
    if !value_is_object(ov) { return value_bool(true); }
    JsObject* o = value_as_object(ov);
    if (o.obj_flags & OBJF_NONEXT) == 0 { return value_bool(false); }
    return value_bool(object_all_locked(o, PROP_CONFIGURABLE));
}

private Value nat_object_isextensible(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    Value ov = arg_at(args, argc, 0);
    if !value_is_object(ov) { return value_bool(false); }
    return value_bool((value_as_object(ov).obj_flags & OBJF_NONEXT) == 0);
}

private Value nat_has_own(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    if !value_is_object(thisv) { return value_bool(false); }
    JsObject* o = value_as_object(thisv);
    Value kv = arg_at(args, argc, 0);
    if (o.obj_flags & OBJF_ARRAY) != 0 && value_is_int(kv) {
        return value_bool(js_array_has(o, value_as_int(kv)));
    }
    i32 rm = gc_root_mark(&vm.heap);
    Value ks = js_to_string_value(vm, kv);
    gc_root(&vm.heap, ks);
    u32 a = bi_atom(vm, sview(ks));
    gc_root_reset(&vm.heap, rm);
    return value_bool(props_get(&o.props, a) != null);
}

private Value nat_object_tostring(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    return new_str(vm, "[object Object]");
}

// --- Array ------------------------------------------------------------------

private JsObject* this_array(VM* vm, Value thisv) {
    if value_is_array(thisv) { return value_as_object(thisv); }
    vm_throw_error(vm, ERR_TYPE, "receiver is not an array");
    return null;
}

private Value nat_array_ctor(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    JsObject* arr = js_new_array(&vm.heap, vm.array_proto);
    if argc == 1 && value_is_number(*(args)) {
        i32 rm = gc_root_mark(&vm.heap);
        gc_root(&vm.heap, value_cell(&arr.head));
        f64 n = js_to_number(*(args));
        i32 ni = cast(i32, n);
        if cast(f64, ni) != n || ni < 0 {
            gc_root_reset(&vm.heap, rm);
            vm_throw_error(vm, ERR_RANGE, "invalid array length");
            return value_undefined();
        }
        js_array_set_length(arr, ni);
        gc_root_reset(&vm.heap, rm);
        return value_cell(&arr.head);
    }
    for i32 i = 0; i < argc; i++ {
        js_array_set(arr, i, *(args + i));
    }
    return value_cell(&arr.head);
}

private Value nat_array_isarray(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    return value_bool(value_is_array(arg_at(args, argc, 0)));
}

private Value nat_array_of(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    JsObject* arr = js_new_array(&vm.heap, vm.array_proto);
    for i32 i = 0; i < argc; i++ {
        js_array_set(arr, i, *(args + i));
    }
    return value_cell(&arr.head);
}

private Value nat_array_from(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    Value src = arg_at(args, argc, 0);
    Value fun = arg_at(args, argc, 1);
    JsObject* arr = js_new_array(&vm.heap, vm.array_proto);
    i32 rm = gc_root_mark(&vm.heap);
    gc_root(&vm.heap, value_cell(&arr.head));
    if value_is_array(src) {
        JsObject* s = value_as_object(src);
        for i32 i = 0; i < s.elen; i++ {
            Value e = js_array_get(s, i);
            if value_is_callable(fun) {
                Value[2] cargs = { e, value_int(i) };
                e = vm_call_value(vm, fun, value_undefined(), &cargs[0], 2);
                if vm.has_pending {
                    gc_root_reset(&vm.heap, rm);
                    return value_undefined();
                }
            }
            js_array_set(arr, i, e);
        }
    } else if value_is_string(src) {
        // code-point iteration, applying the optional map function
        str s = sview(src);
        i32 off = 0;
        i32 idx = 0;
        while off < s.len {
            i32 n;
            ignore utf8_decode(s, off, &n);
            str one;
            one.data = s.data + off;
            one.len = n;
            Value cs = new_str(vm, one);
            if value_is_callable(fun) {
                gc_root(&vm.heap, cs);
                Value[2] cargs = { cs, value_int(idx) };
                cs = vm_call_value(vm, fun, value_undefined(), &cargs[0], 2);
                if vm.has_pending {
                    gc_root_reset(&vm.heap, rm);
                    return value_undefined();
                }
            }
            js_array_set(arr, idx, cs);
            off += n;
            idx++;
        }
    } else if value_is_object(src) || value_is_map(src) || value_is_generator(src) {
        // iterable protocol (Set, Map, generators, custom iterables) or
        // an array-like with a length property
        Value itfn;
        if vm_get_prop_value(vm, src, vm_sym_iterator_id(vm), &itfn) && value_is_callable(itfn) {
            Value iter;
            if !vm_get_iterator(vm, src, &iter) {
                gc_root_reset(&vm.heap, rm);
                return value_undefined();
            }
            gc_root(&vm.heap, iter);
            i32 n = 0;
            while true {
                Value val;
                bool done;
                if !vm_iter_next(vm, iter, &val, &done) {
                    gc_root_reset(&vm.heap, rm);
                    return value_undefined();
                }
                if done { break; }
                gc_root(&vm.heap, val);
                if value_is_callable(fun) {
                    Value[2] cargs = { val, value_int(n) };
                    val = vm_call_value(vm, fun, value_undefined(), &cargs[0], 2);
                    if vm.has_pending {
                        gc_root_reset(&vm.heap, rm);
                        return value_undefined();
                    }
                }
                js_array_set(arr, n, val);
                n++;
            }
        } else {
            // array-like: read length and indexed elements
            Value lenv;
            i32 len = 0;
            if vm_get_prop_value(vm, src, vm.atom_length, &lenv) && value_is_number(lenv) {
                len = to_int_arg(lenv);
            }
            for i32 i = 0; i < len; i++ {
                Value e;
                string ks = format("{}", i);
                u32 ka = atom_intern(&vm.atoms, ks);
                free(ks);
                ignore vm_get_prop_value(vm, src, ka, &e);
                if value_is_callable(fun) {
                    Value[2] cargs = { e, value_int(i) };
                    e = vm_call_value(vm, fun, value_undefined(), &cargs[0], 2);
                    if vm.has_pending {
                        gc_root_reset(&vm.heap, rm);
                        return value_undefined();
                    }
                }
                js_array_set(arr, i, e);
            }
        }
    }
    gc_root_reset(&vm.heap, rm);
    return value_cell(&arr.head);
}

private Value nat_arr_push(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    JsObject* a = this_array(vm, thisv);
    if a == null { return value_undefined(); }
    for i32 i = 0; i < argc; i++ {
        js_array_set(a, a.elen, *(args + i));
    }
    return value_int(a.elen);
}

private Value nat_arr_pop(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    JsObject* a = this_array(vm, thisv);
    if a == null { return value_undefined(); }
    if a.elen == 0 { return value_undefined(); }
    Value v = js_array_get(a, a.elen - 1);
    a.elen--;
    return v;
}

private Value nat_arr_shift(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    JsObject* a = this_array(vm, thisv);
    if a == null { return value_undefined(); }
    if a.elen == 0 { return value_undefined(); }
    Value v = js_array_get(a, 0);
    for i32 i = 0; i + 1 < a.elen; i++ {
        *(a.elems + i) = *(a.elems + i + 1);
    }
    a.elen--;
    return v;
}

private Value nat_arr_unshift(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    JsObject* a = this_array(vm, thisv);
    if a == null { return value_undefined(); }
    i32 old = a.elen;
    if old > 0 {
        js_array_set(a, old + argc - 1, value_undefined());
        for i32 i = old - 1; i >= 0; i-- {
            *(a.elems + i + argc) = *(a.elems + i);
        }
    }
    for i32 i = 0; i < argc; i++ {
        js_array_set(a, i, *(args + i));
    }
    return value_int(a.elen);
}

// Negative-tolerant range clamp shared by slice-style methods.
private i32 rel_index(i32 v, i32 len) {
    if v < 0 {
        v += len;
        if v < 0 { v = 0; }
    }
    if v > len { v = len; }
    return v;
}

private Value nat_arr_copywithin(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    JsObject* o = this_array(vm, thisv);
    if o == null { return value_undefined(); }
    i32 len = o.elen;
    i32 target = rel_index(argc > 0 ? to_int_arg(*(args)) : 0, len);
    i32 start = rel_index(argc > 1 ? to_int_arg(*(args + 1)) : 0, len);
    i32 end = len;
    if argc > 2 && !value_is_undefined(*(args + 2)) {
        end = rel_index(to_int_arg(*(args + 2)), len);
    }
    i32 count = end - start;
    if count > len - target { count = len - target; }
    if count > 0 {
        Value* tmp = alloc<Value>(count);
        for i32 i = 0; i < count; i++ { *(tmp + i) = js_array_get(o, start + i); }
        for i32 i = 0; i < count; i++ { js_array_set(o, target + i, *(tmp + i)); }
        free(tmp);
    }
    return thisv;
}

private Value nat_arr_slice(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    JsObject* a = this_array(vm, thisv);
    if a == null { return value_undefined(); }
    i32 start = rel_index(argc > 0 ? to_int_arg(*(args)) : 0, a.elen);
    i32 end = a.elen;
    if argc > 1 && !value_is_undefined(*(args + 1)) {
        end = rel_index(to_int_arg(*(args + 1)), a.elen);
    }
    JsObject* r = js_new_array(&vm.heap, vm.array_proto);
    i32 rm = gc_root_mark(&vm.heap);
    gc_root(&vm.heap, value_cell(&r.head));
    i32 n = 0;
    for i32 i = start; i < end; i++ {
        js_array_set(r, n, js_array_raw(a, i));   // preserve holes
        n++;
    }
    js_array_set_length(r, n);
    gc_root_reset(&vm.heap, rm);
    return value_cell(&r.head);
}

private Value nat_arr_splice(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    JsObject* a = this_array(vm, thisv);
    if a == null { return value_undefined(); }
    i32 start = rel_index(argc > 0 ? to_int_arg(*(args)) : 0, a.elen);
    i32 del = a.elen - start;
    if argc > 1 {
        del = to_int_arg(*(args + 1));
        if del < 0 { del = 0; }
        if del > a.elen - start { del = a.elen - start; }
    }
    i32 n_items = argc > 2 ? argc - 2 : 0;
    JsObject* removed = js_new_array(&vm.heap, vm.array_proto);
    i32 rm = gc_root_mark(&vm.heap);
    gc_root(&vm.heap, value_cell(&removed.head));
    for i32 i = 0; i < del; i++ {
        js_array_set(removed, i, js_array_get(a, start + i));
    }
    i32 old_len = a.elen;
    i32 new_len = old_len - del + n_items;
    if n_items > del {
        js_array_set(a, new_len - 1, value_undefined());
        for i32 i = old_len - 1; i >= start + del; i-- {
            *(a.elems + i + n_items - del) = *(a.elems + i);
        }
    } else if n_items < del {
        for i32 i = start + del; i < old_len; i++ {
            *(a.elems + i - del + n_items) = *(a.elems + i);
        }
        a.elen = new_len;
    }
    for i32 i = 0; i < n_items; i++ {
        js_array_set(a, start + i, *(args + 2 + i));
    }
    gc_root_reset(&vm.heap, rm);
    return value_cell(&removed.head);
}

private Value nat_arr_concat(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    JsObject* a = this_array(vm, thisv);
    if a == null { return value_undefined(); }
    JsObject* r = js_new_array(&vm.heap, vm.array_proto);
    i32 rm = gc_root_mark(&vm.heap);
    gc_root(&vm.heap, value_cell(&r.head));
    i32 n = 0;
    for i32 i = 0; i < a.elen; i++ {
        js_array_set(r, n, js_array_raw(a, i));   // preserve holes
        n++;
    }
    for i32 s = 0; s < argc; s++ {
        Value v = *(args + s);
        if value_is_array(v) {
            JsObject* o = value_as_object(v);
            for i32 i = 0; i < o.elen; i++ {
                js_array_set(r, n, js_array_raw(o, i));
                n++;
            }
        } else {
            js_array_set(r, n, v);
            n++;
        }
    }
    js_array_set_length(r, n);
    gc_root_reset(&vm.heap, rm);
    return value_cell(&r.head);
}

private Value nat_arr_join(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    JsObject* a = this_array(vm, thisv);
    if a == null { return value_undefined(); }
    str sep = ",";
    i32 rm = gc_root_mark(&vm.heap);
    Value sepv = arg_at(args, argc, 0);
    if !value_is_undefined(sepv) {
        Value ss = js_to_string_value(vm, sepv);
        gc_root(&vm.heap, ss);
        sep = sview(ss);
    }
    str_buf sb;
    str_buf_init(&sb);
    for i32 i = 0; i < a.elen; i++ {
        if i > 0 { str_buf_add(&sb, sep); }
        Value e = js_array_get(a, i);
        if value_is_undefined(e) || value_is_null(e) { continue; }
        Value es = js_to_string_value(vm, e);
        gc_root(&vm.heap, es);
        str_buf_add(&sb, sview(es));
    }
    Value r = new_str(vm, str_buf_to_str(&sb));
    str_buf_free(&sb);
    gc_root_reset(&vm.heap, rm);
    return r;
}

private Value nat_arr_indexof(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    JsObject* a = this_array(vm, thisv);
    if a == null { return value_undefined(); }
    Value needle = arg_at(args, argc, 0);
    i32 start_at = argc > 1 ? rel_index(to_int_arg(*(args + 1)), a.elen) : 0;
    for i32 i = start_at; i < a.elen; i++ {
        if !js_array_has(a, i) { continue; }   // indexOf skips holes
        if js_strict_eq(js_array_get(a, i), needle) { return value_int(i); }
    }
    return value_int(-1);
}

private Value nat_arr_includes(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    JsObject* a = this_array(vm, thisv);
    if a == null { return value_undefined(); }
    Value needle = arg_at(args, argc, 0);
    for i32 i = 0; i < a.elen; i++ {
        Value e = js_array_get(a, i);
        if js_strict_eq(e, needle) { return value_bool(true); }
        // SameValueZero: NaN matches NaN
        if value_is_number(e) && value_is_number(needle) {
            f64 x = js_to_number(e);
            f64 y = js_to_number(needle);
            if x != x && y != y { return value_bool(true); }
        }
    }
    return value_bool(false);
}

// Shared iteration driver: mode selects map/filter/forEach/some/every/
// find/findIndex.
const i32 IT_MAP = 0;
const i32 IT_FILTER = 1;
const i32 IT_FOREACH = 2;
const i32 IT_SOME = 3;
const i32 IT_EVERY = 4;
const i32 IT_FIND = 5;
const i32 IT_FINDINDEX = 6;

private Value nat_arr_lastindexof(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    JsObject* a = this_array(vm, thisv);
    if a == null { return value_undefined(); }
    Value needle = arg_at(args, argc, 0);
    i32 start = a.elen - 1;
    if argc > 1 && !value_is_undefined(*(args + 1)) {
        i32 s = to_int_arg(*(args + 1));
        if s < 0 { s += a.elen; }
        if s < start { start = s; }
    }
    for i32 i = start; i >= 0; i-- {
        if !js_array_has(a, i) { continue; }   // skips holes, like indexOf
        if js_strict_eq(js_array_get(a, i), needle) { return value_int(i); }
    }
    return value_int(-1);
}

// A dense copy (holes become undefined) for the ES2023 copying methods.
private JsObject* arr_dense_copy(VM* vm, JsObject* a) {
    JsObject* r = js_new_array(&vm.heap, vm.array_proto);
    for i32 i = 0; i < a.elen; i++ {
        js_array_set(r, i, js_array_get(a, i));
    }
    return r;
}

private Value nat_arr_toreversed(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    JsObject* a = this_array(vm, thisv);
    if a == null { return value_undefined(); }
    JsObject* r = js_new_array(&vm.heap, vm.array_proto);
    i32 rm = gc_root_mark(&vm.heap);
    gc_root(&vm.heap, value_cell(&r.head));
    for i32 i = 0; i < a.elen; i++ {
        js_array_set(r, i, js_array_get(a, a.elen - 1 - i));
    }
    gc_root_reset(&vm.heap, rm);
    return value_cell(&r.head);
}

private Value nat_arr_with(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    JsObject* a = this_array(vm, thisv);
    if a == null { return value_undefined(); }
    i32 idx = to_int_arg(arg_at(args, argc, 0));
    if idx < 0 { idx += a.elen; }
    if idx < 0 || idx >= a.elen {
        vm_throw_error(vm, ERR_RANGE, "invalid index");
        return value_undefined();
    }
    JsObject* r = js_new_array(&vm.heap, vm.array_proto);
    i32 rm = gc_root_mark(&vm.heap);
    gc_root(&vm.heap, value_cell(&r.head));
    for i32 i = 0; i < a.elen; i++ {
        js_array_set(r, i, i == idx ? arg_at(args, argc, 1) : js_array_get(a, i));
    }
    gc_root_reset(&vm.heap, rm);
    return value_cell(&r.head);
}

private Value arr_iterate(VM* vm, Value thisv, Value* args, i32 argc, i32 mode) {
    JsObject* a = this_array(vm, thisv);
    if a == null { return value_undefined(); }
    Value fun = arg_at(args, argc, 0);
    if !value_is_callable(fun) {
        vm_throw_error(vm, ERR_TYPE, "callback is not a function");
        return value_undefined();
    }
    JsObject* out = null;
    i32 rm = gc_root_mark(&vm.heap);
    if mode == IT_MAP || mode == IT_FILTER {
        out = js_new_array(&vm.heap, vm.array_proto);
        gc_root(&vm.heap, value_cell(&out.head));
    }
    // find/findIndex visit holes as undefined; the rest skip them
    bool skip_holes = mode != IT_FIND && mode != IT_FINDINDEX;
    i32 n = 0;
    for i32 i = 0; i < a.elen; i++ {
        if skip_holes && !js_array_has(a, i) { continue; }
        Value e = js_array_get(a, i);
        Value[3] cargs = { e, value_int(i), thisv };
        Value r = vm_call_value(vm, fun, value_undefined(), &cargs[0], 3);
        if vm.has_pending {
            gc_root_reset(&vm.heap, rm);
            return value_undefined();
        }
        if mode == IT_MAP {
            js_array_set(out, i, r);
        } else if mode == IT_FILTER {
            if js_truthy(r) {
                js_array_set(out, n, e);
                n++;
            }
        } else if mode == IT_SOME {
            if js_truthy(r) {
                gc_root_reset(&vm.heap, rm);
                return value_bool(true);
            }
        } else if mode == IT_EVERY {
            if !js_truthy(r) {
                gc_root_reset(&vm.heap, rm);
                return value_bool(false);
            }
        } else if mode == IT_FIND {
            if js_truthy(r) {
                gc_root_reset(&vm.heap, rm);
                return e;
            }
        } else if mode == IT_FINDINDEX {
            if js_truthy(r) {
                gc_root_reset(&vm.heap, rm);
                return value_int(i);
            }
        }
    }
    // map preserves the source length, holes and all
    if mode == IT_MAP { js_array_set_length(out, a.elen); }
    gc_root_reset(&vm.heap, rm);
    if mode == IT_MAP || mode == IT_FILTER { return value_cell(&out.head); }
    if mode == IT_SOME { return value_bool(false); }
    if mode == IT_EVERY { return value_bool(true); }
    if mode == IT_FINDINDEX { return value_int(-1); }
    return value_undefined();
}

private Value nat_arr_map(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    return arr_iterate(as_vm(vmp), thisv, args, argc, IT_MAP);
}
private Value nat_arr_filter(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    return arr_iterate(as_vm(vmp), thisv, args, argc, IT_FILTER);
}
private Value nat_arr_foreach(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    return arr_iterate(as_vm(vmp), thisv, args, argc, IT_FOREACH);
}
private Value nat_arr_some(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    return arr_iterate(as_vm(vmp), thisv, args, argc, IT_SOME);
}
private Value nat_arr_every(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    return arr_iterate(as_vm(vmp), thisv, args, argc, IT_EVERY);
}
private Value nat_arr_find(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    return arr_iterate(as_vm(vmp), thisv, args, argc, IT_FIND);
}
private Value nat_arr_findindex(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    return arr_iterate(as_vm(vmp), thisv, args, argc, IT_FINDINDEX);
}

private Value nat_arr_reduce(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    JsObject* a = this_array(vm, thisv);
    if a == null { return value_undefined(); }
    Value fun = arg_at(args, argc, 0);
    if !value_is_callable(fun) {
        vm_throw_error(vm, ERR_TYPE, "callback is not a function");
        return value_undefined();
    }
    i32 i = 0;
    Value acc;
    if argc > 1 {
        acc = *(args + 1);
    } else {
        // seed with the first present element (skip leading holes)
        while i < a.elen && !js_array_has(a, i) { i++; }
        if i >= a.elen {
            vm_throw_error(vm, ERR_TYPE, "reduce of empty array with no initial value");
            return value_undefined();
        }
        acc = js_array_get(a, i);
        i++;
    }
    i32 rm = gc_root_mark(&vm.heap);
    while i < a.elen {
        if !js_array_has(a, i) { i++; continue; }
        gc_root(&vm.heap, acc);
        Value[4] cargs = { acc, js_array_get(a, i), value_int(i), thisv };
        acc = vm_call_value(vm, fun, value_undefined(), &cargs[0], 4);
        gc_root_reset(&vm.heap, rm);
        if vm.has_pending { return value_undefined(); }
        i++;
    }
    return acc;
}

private Value nat_arr_reduceright(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    JsObject* a = this_array(vm, thisv);
    if a == null { return value_undefined(); }
    Value fun = arg_at(args, argc, 0);
    if !value_is_callable(fun) {
        vm_throw_error(vm, ERR_TYPE, "callback is not a function");
        return value_undefined();
    }
    i32 i = a.elen - 1;
    Value acc;
    if argc > 1 {
        acc = *(args + 1);
    } else {
        while i >= 0 && !js_array_has(a, i) { i--; }
        if i < 0 {
            vm_throw_error(vm, ERR_TYPE, "reduce of empty array with no initial value");
            return value_undefined();
        }
        acc = js_array_get(a, i);
        i--;
    }
    i32 rm = gc_root_mark(&vm.heap);
    while i >= 0 {
        if !js_array_has(a, i) { i--; continue; }
        gc_root(&vm.heap, acc);
        Value[4] cargs = { acc, js_array_get(a, i), value_int(i), thisv };
        acc = vm_call_value(vm, fun, value_undefined(), &cargs[0], 4);
        gc_root_reset(&vm.heap, rm);
        if vm.has_pending { return value_undefined(); }
        i--;
    }
    return acc;
}

private Value nat_arr_at(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    JsObject* a = this_array(vm, thisv);
    if a == null { return value_undefined(); }
    i32 i = to_int_arg(arg_at(args, argc, 0));
    if i < 0 { i += a.elen; }
    if i < 0 || i >= a.elen { return value_undefined(); }
    return js_array_get(a, i);
}

private Value nat_arr_findlast(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    JsObject* a = this_array(vm, thisv);
    if a == null { return value_undefined(); }
    Value fun = arg_at(args, argc, 0);
    if !value_is_callable(fun) {
        vm_throw_error(vm, ERR_TYPE, "callback is not a function");
        return value_undefined();
    }
    for i32 i = a.elen - 1; i >= 0; i-- {
        Value e = js_array_get(a, i);
        Value[3] ca = { e, value_int(i), thisv };
        Value r = vm_call_value(vm, fun, value_undefined(), &ca[0], 3);
        if vm.has_pending { return value_undefined(); }
        if js_truthy(r) { return e; }
    }
    return value_undefined();
}

// Flattens one level (arrays only) into dst.
private void flatten_into(VM* vm, JsObject* src, JsObject* dst, i32 depth) {
    for i32 i = 0; i < src.elen; i++ {
        Value e = js_array_get(src, i);
        if depth > 0 && value_is_array(e) {
            flatten_into(vm, value_as_object(e), dst, depth - 1);
        } else {
            js_array_set(dst, dst.elen, e);
        }
    }
}

private Value nat_arr_flat(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    JsObject* a = this_array(vm, thisv);
    if a == null { return value_undefined(); }
    i32 depth = argc > 0 && !value_is_undefined(*(args)) ? to_int_arg(*(args)) : 1;
    JsObject* out = js_new_array(&vm.heap, vm.array_proto);
    i32 rm = gc_root_mark(&vm.heap);
    gc_root(&vm.heap, value_cell(&out.head));
    flatten_into(vm, a, out, depth);
    gc_root_reset(&vm.heap, rm);
    return value_cell(&out.head);
}

private Value nat_arr_flatmap(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    JsObject* a = this_array(vm, thisv);
    if a == null { return value_undefined(); }
    Value fun = arg_at(args, argc, 0);
    if !value_is_callable(fun) {
        vm_throw_error(vm, ERR_TYPE, "callback is not a function");
        return value_undefined();
    }
    JsObject* out = js_new_array(&vm.heap, vm.array_proto);
    i32 rm = gc_root_mark(&vm.heap);
    gc_root(&vm.heap, value_cell(&out.head));
    for i32 i = 0; i < a.elen; i++ {
        Value[3] ca = { js_array_get(a, i), value_int(i), thisv };
        Value r = vm_call_value(vm, fun, value_undefined(), &ca[0], 3);
        if vm.has_pending { gc_root_reset(&vm.heap, rm); return value_undefined(); }
        gc_root(&vm.heap, r);
        if value_is_array(r) {
            JsObject* ro = value_as_object(r);
            for i32 j = 0; j < ro.elen; j++ {
                js_array_set(out, out.elen, js_array_get(ro, j));
            }
        } else {
            js_array_set(out, out.elen, r);
        }
    }
    gc_root_reset(&vm.heap, rm);
    return value_cell(&out.head);
}

private Value nat_arr_reverse(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    JsObject* a = this_array(vm, thisv);
    if a == null { return value_undefined(); }
    i32 i = 0;
    i32 j = a.elen - 1;
    while i < j {
        Value t = *(a.elems + i);
        *(a.elems + i) = *(a.elems + j);
        *(a.elems + j) = t;
        i++;
        j--;
    }
    return thisv;
}

private Value nat_arr_fill(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    JsObject* a = this_array(vm, thisv);
    if a == null { return value_undefined(); }
    Value v = arg_at(args, argc, 0);
    i32 start = argc > 1 ? rel_index(to_int_arg(*(args + 1)), a.elen) : 0;
    i32 end = argc > 2 ? rel_index(to_int_arg(*(args + 2)), a.elen) : a.elen;
    for i32 i = start; i < end; i++ {
        *(a.elems + i) = v;
    }
    return thisv;
}

// Insertion sort; comparator errors abort mid-sort like a throw would.
private Value nat_arr_sort(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    JsObject* a = this_array(vm, thisv);
    if a == null { return value_undefined(); }
    Value cmp = arg_at(args, argc, 0);
    bool has_cmp = value_is_callable(cmp);
    for i32 i = 1; i < a.elen; i++ {
        Value key = *(a.elems + i);
        i32 j = i - 1;
        while j >= 0 {
            Value other = *(a.elems + j);
            bool greater = false;
            if has_cmp {
                Value[2] cargs = { other, key };
                Value r = vm_call_value(vm, cmp, value_undefined(), &cargs[0], 2);
                if vm.has_pending { return value_undefined(); }
                greater = js_to_number(r) > 0.0;
            } else {
                i32 rm = gc_root_mark(&vm.heap);
                Value sa = js_to_string_value(vm, other);
                gc_root(&vm.heap, sa);
                Value sb2 = js_to_string_value(vm, key);
                gc_root(&vm.heap, sb2);
                greater = js_str_cmp(sview(sa), sview(sb2)) > 0;
                gc_root_reset(&vm.heap, rm);
            }
            if !greater { break; }
            *(a.elems + j + 1) = other;
            j--;
        }
        *(a.elems + j + 1) = key;
    }
    return thisv;
}

private Value nat_arr_tosorted(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    JsObject* a = this_array(vm, thisv);
    if a == null { return value_undefined(); }
    i32 rm = gc_root_mark(&vm.heap);
    JsObject* r = arr_dense_copy(vm, a);
    Value rv = value_cell(&r.head);
    gc_root(&vm.heap, rv);
    Value sorted = nat_arr_sort(vmp, callee, rv, args, argc);
    gc_root_reset(&vm.heap, rm);
    return sorted;
}

// --- String -------------------------------------------------------------------

private Value nat_string_ctor(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    if argc == 0 { return new_str(vm, ""); }
    return js_to_string_value(vm, *(args));
}

// Each argument is a UTF-16 code unit (ToUint16). Adjacent high+low
// surrogates combine into an astral code point; a lone surrogate is
// kept as WTF-8.
private Value nat_string_fromcharcode(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    str_buf sb;
    str_buf_init(&sb);
    i32 i = 0;
    while i < argc {
        f64 d = js_to_number(*(args + i));
        i32 unit = d == d ? (cast(i32, cast(i64, d)) & 0xFFFF) : 0;
        if unit >= 0xD800 && unit <= 0xDBFF && i + 1 < argc {
            f64 d2 = js_to_number(*(args + i + 1));
            i32 low = d2 == d2 ? (cast(i32, cast(i64, d2)) & 0xFFFF) : 0;
            if low >= 0xDC00 && low <= 0xDFFF {
                wtf8_put_cp(&sb, 0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00));
                i += 2;
                continue;
            }
        }
        wtf8_put_cp(&sb, unit);
        i++;
    }
    Value r = new_str(vm, str_buf_to_str(&sb));
    str_buf_free(&sb);
    return r;
}

// String.raw(strings, ...subs): joins strings.raw[i] with subs between.
private Value nat_string_raw(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    Value strings = arg_at(args, argc, 0);
    i32 rm = gc_root_mark(&vm.heap);
    Value raw;
    if !value_is_object(strings)
        || !vm_get_prop_value(vm, strings, bi_atom(vm, "raw"), &raw)
        || !value_is_array(raw) {
        gc_root_reset(&vm.heap, rm);
        return new_str(vm, "");
    }
    gc_root(&vm.heap, raw);
    JsObject* ra = value_as_object(raw);
    str_buf sb;
    str_buf_init(&sb);
    for i32 i = 0; i < ra.elen; i++ {
        Value seg = js_to_string_value(vm, js_array_get(ra, i));
        gc_root(&vm.heap, seg);
        str_buf_add(&sb, sview(seg));
        if i + 1 < ra.elen && i + 1 < argc {
            Value s = js_to_string_value(vm, *(args + i + 1));
            gc_root(&vm.heap, s);
            str_buf_add(&sb, sview(s));
        }
    }
    Value r = new_str(vm, str_buf_to_str(&sb));
    str_buf_free(&sb);
    gc_root_reset(&vm.heap, rm);
    return r;
}

// Each argument is a Unicode code point (0..0x10FFFF).
private Value nat_string_fromcodepoint(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    str_buf sb;
    str_buf_init(&sb);
    for i32 i = 0; i < argc; i++ {
        f64 d = js_to_number(*(args + i));
        i32 cp = cast(i32, cast(i64, d));
        if d != d || cast(f64, cp) != d || cp < 0 || cp > 0x10FFFF {
            str_buf_free(&sb);
            vm_throw_error(vm, ERR_RANGE, "Invalid code point");
            return value_undefined();
        }
        wtf8_put_cp(&sb, cp);
    }
    Value r = new_str(vm, str_buf_to_str(&sb));
    str_buf_free(&sb);
    return r;
}

// Builds the UTF-16 unit range [start, end) of a string value as a new
// string. ASCII strings (u16len == byte len) index directly.
private Value str_u16_range(VM* vm, Value sv, i32 start, i32 end) {
    GcString* g = value_as_string(sv);
    str s = gc_string_view(g);
    if start < 0 { start = 0; }
    if end > g.u16len { end = g.u16len; }
    if end < start { end = start; }
    if g.u16len == g.len {
        str sub;
        sub.data = s.data + start;
        sub.len = end - start;
        return new_str(vm, sub);
    }
    str_buf sb;
    str_buf_init(&sb);
    u16_slice_into(&sb, s, start, end);
    Value r = new_str(vm, str_buf_to_str(&sb));
    str_buf_free(&sb);
    return r;
}

private Value nat_str_charat(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    i32 rm = gc_root_mark(&vm.heap);
    Value sv2 = js_to_string_value(vm, thisv);
    gc_root(&vm.heap, sv2);
    i32 i = to_int_arg(arg_at(args, argc, 0));
    i32 ulen = value_as_string(sv2).u16len;
    Value r;
    if i >= 0 && i < ulen {
        r = str_u16_range(vm, sv2, i, i + 1);
    } else {
        r = new_str(vm, "");
    }
    gc_root_reset(&vm.heap, rm);
    return r;
}

private Value nat_str_charcodeat(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    i32 rm = gc_root_mark(&vm.heap);
    Value sv2 = js_to_string_value(vm, thisv);
    gc_root(&vm.heap, sv2);
    str s = sview(sv2);
    i32 i = to_int_arg(arg_at(args, argc, 0));
    i32 unit = u16_unit_at(s, i);
    gc_root_reset(&vm.heap, rm);
    if unit >= 0 { return value_int(unit); }
    return value_number(0.0 / 0.0);
}

private Value nat_str_codepointat(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    i32 rm = gc_root_mark(&vm.heap);
    Value sv2 = js_to_string_value(vm, thisv);
    gc_root(&vm.heap, sv2);
    str s = sview(sv2);
    i32 i = to_int_arg(arg_at(args, argc, 0));
    i32 hi = u16_unit_at(s, i);
    gc_root_reset(&vm.heap, rm);
    if hi < 0 { return value_undefined(); }
    // a leading high surrogate followed by a low surrogate combines
    if hi >= 0xD800 && hi <= 0xDBFF {
        i32 lo = u16_unit_at(s, i + 1);
        if lo >= 0xDC00 && lo <= 0xDFFF {
            return value_int(0x10000 + ((hi - 0xD800) << 10) + (lo - 0xDC00));
        }
    }
    return value_int(hi);
}

private i32 str_find_from(str hay, str needle, i32 start_at) {
    if start_at < 0 { start_at = 0; }
    if needle.len == 0 { return start_at <= hay.len ? start_at : hay.len; }
    for i32 i = start_at; i + needle.len <= hay.len; i++ {
        str win;
        win.data = hay.data + i;
        win.len = needle.len;
        if str_equal(win, needle) { return i; }
    }
    return -1;
}

// Shared this/arg string extraction; both stay rooted until reset.
private Value nat_str_indexof(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    i32 rm = gc_root_mark(&vm.heap);
    Value sv2 = js_to_string_value(vm, thisv);
    gc_root(&vm.heap, sv2);
    Value nv = js_to_string_value(vm, arg_at(args, argc, 0));
    gc_root(&vm.heap, nv);
    GcString* hg = value_as_string(sv2);
    str hay = gc_string_view(hg);
    bool ascii = hg.u16len == hg.len;
    i32 start_u = argc > 1 ? to_int_arg(*(args + 1)) : 0;
    i32 start_b = ascii ? start_u : u16_offset(hay, start_u);
    i32 f = str_find_from(hay, sview(nv), start_b);
    i32 r = f < 0 ? -1 : (ascii ? f : u16_byte_to_unit(hay, f));
    gc_root_reset(&vm.heap, rm);
    return value_int(r);
}

private Value nat_str_lastindexof(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    i32 rm = gc_root_mark(&vm.heap);
    Value sv2 = js_to_string_value(vm, thisv);
    gc_root(&vm.heap, sv2);
    Value nv = js_to_string_value(vm, arg_at(args, argc, 0));
    gc_root(&vm.heap, nv);
    GcString* hg = value_as_string(sv2);
    str hay = gc_string_view(hg);
    str needle = sview(nv);
    i32 best = -1;
    i32 i = 0;
    while true {
        i32 f = str_find_from(hay, needle, i);
        if f < 0 { break; }
        best = f;
        i = f + 1;
    }
    bool ascii = hg.u16len == hg.len;
    i32 r = best < 0 ? -1 : (ascii ? best : u16_byte_to_unit(hay, best));
    gc_root_reset(&vm.heap, rm);
    return value_int(r);
}

private Value nat_str_includes(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    i32 rm = gc_root_mark(&vm.heap);
    Value sv2 = js_to_string_value(vm, thisv);
    gc_root(&vm.heap, sv2);
    Value nv = js_to_string_value(vm, arg_at(args, argc, 0));
    gc_root(&vm.heap, nv);
    bool r = str_find_from(sview(sv2), sview(nv), 0) >= 0;
    gc_root_reset(&vm.heap, rm);
    return value_bool(r);
}

private Value nat_str_startswith(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    i32 rm = gc_root_mark(&vm.heap);
    Value sv2 = js_to_string_value(vm, thisv);
    gc_root(&vm.heap, sv2);
    Value nv = js_to_string_value(vm, arg_at(args, argc, 0));
    gc_root(&vm.heap, nv);
    bool r = str_starts_with(sview(sv2), sview(nv));
    gc_root_reset(&vm.heap, rm);
    return value_bool(r);
}

private Value nat_str_endswith(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    i32 rm = gc_root_mark(&vm.heap);
    Value sv2 = js_to_string_value(vm, thisv);
    gc_root(&vm.heap, sv2);
    Value nv = js_to_string_value(vm, arg_at(args, argc, 0));
    gc_root(&vm.heap, nv);
    bool r = str_ends_with(sview(sv2), sview(nv));
    gc_root_reset(&vm.heap, rm);
    return value_bool(r);
}

private Value nat_str_slice(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    i32 rm = gc_root_mark(&vm.heap);
    Value sv2 = js_to_string_value(vm, thisv);
    gc_root(&vm.heap, sv2);
    i32 ulen = value_as_string(sv2).u16len;
    i32 start = rel_index(argc > 0 ? to_int_arg(*(args)) : 0, ulen);
    i32 end = ulen;
    if argc > 1 && !value_is_undefined(*(args + 1)) {
        end = rel_index(to_int_arg(*(args + 1)), ulen);
    }
    if end < start { end = start; }
    Value r = str_u16_range(vm, sv2, start, end);
    gc_root_reset(&vm.heap, rm);
    return r;
}

private Value nat_str_substring(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    i32 rm = gc_root_mark(&vm.heap);
    Value sv2 = js_to_string_value(vm, thisv);
    gc_root(&vm.heap, sv2);
    i32 ulen = value_as_string(sv2).u16len;
    i32 a = argc > 0 ? to_int_arg(*(args)) : 0;
    i32 b = ulen;
    if argc > 1 && !value_is_undefined(*(args + 1)) {
        b = to_int_arg(*(args + 1));
    }
    if a < 0 { a = 0; }
    if b < 0 { b = 0; }
    if a > ulen { a = ulen; }
    if b > ulen { b = ulen; }
    if a > b {
        i32 t = a;
        a = b;
        b = t;
    }
    Value r = str_u16_range(vm, sv2, a, b);
    gc_root_reset(&vm.heap, rm);
    return r;
}

// Case-maps one code point: ASCII plus the Latin-1 letters. Beyond
// Latin-1 (Greek, Cyrillic, ...) is left unmapped — a documented gap.
private i32 case_map_cp(i32 cp, bool upper) {
    if upper {
        if cp >= 'a' && cp <= 'z' { return cp - 32; }
        if cp >= 0xE0 && cp <= 0xFE && cp != 0xF7 { return cp - 0x20; }
        if cp == 0xFF { return 0x178; }   // ÿ -> Ÿ
        if cp == 0xB5 { return 0x39C; }   // µ -> Μ (Greek Mu)
        return cp;
    }
    if cp >= 'A' && cp <= 'Z' { return cp + 32; }
    if cp >= 0xC0 && cp <= 0xDE && cp != 0xD7 { return cp + 0x20; }
    if cp == 0x178 { return 0xFF; }       // Ÿ -> ÿ
    return cp;
}

private Value str_case_map(VM* vm, Value thisv, bool upper) {
    i32 rm = gc_root_mark(&vm.heap);
    Value sv2 = js_to_string_value(vm, thisv);
    gc_root(&vm.heap, sv2);
    str s = sview(sv2);
    str_buf sb;
    str_buf_init(&sb);
    i32 off = 0;
    while off < s.len {
        i32 n;
        i32 cp = utf8_decode(s, off, &n);
        off += n;
        if upper && cp == 0xDF {          // ß -> SS
            wtf8_put_cp(&sb, 'S');
            wtf8_put_cp(&sb, 'S');
        } else {
            wtf8_put_cp(&sb, case_map_cp(cp, upper));
        }
    }
    Value r = new_str(vm, str_buf_to_str(&sb));
    str_buf_free(&sb);
    gc_root_reset(&vm.heap, rm);
    return r;
}

private Value nat_str_toupper(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    return str_case_map(as_vm(vmp), thisv, true);
}

private Value nat_str_tolower(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    return str_case_map(as_vm(vmp), thisv, false);
}

// Legacy substr(start, length) with a negative-start offset from the end.
private Value nat_str_substr(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    i32 rm = gc_root_mark(&vm.heap);
    Value sv2 = js_to_string_value(vm, thisv);
    gc_root(&vm.heap, sv2);
    i32 ulen = value_as_string(sv2).u16len;
    i32 start = argc > 0 ? to_int_arg(*(args)) : 0;
    if start < 0 {
        start = ulen + start;
        if start < 0 { start = 0; }
    }
    if start > ulen { start = ulen; }
    i32 len = ulen - start;
    if argc > 1 && !value_is_undefined(*(args + 1)) {
        len = to_int_arg(*(args + 1));
        if len < 0 { len = 0; }
    }
    if start + len > ulen { len = ulen - start; }
    Value r = str_u16_range(vm, sv2, start, start + len);
    gc_root_reset(&vm.heap, rm);
    return r;
}

private Value nat_str_localecompare(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    i32 rm = gc_root_mark(&vm.heap);
    Value av = js_to_string_value(vm, thisv);
    gc_root(&vm.heap, av);
    Value bv = js_to_string_value(vm, arg_at(args, argc, 0));
    gc_root(&vm.heap, bv);
    i32 c = js_str_cmp(sview(av), sview(bv));
    gc_root_reset(&vm.heap, rm);
    return value_int(c < 0 ? -1 : (c > 0 ? 1 : 0));
}

// Unicode normalization is a no-op: already-composed input (the common
// case) round-trips unchanged.
private Value nat_str_normalize(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    return js_to_string_value(as_vm(vmp), thisv);
}

private bool is_ws_byte(u8 c) {
    return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == 11 || c == 12;
}

private Value nat_str_trim(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    i32 rm = gc_root_mark(&vm.heap);
    Value sv2 = js_to_string_value(vm, thisv);
    gc_root(&vm.heap, sv2);
    str s = sview(sv2);
    i32 a = 0;
    i32 b = s.len;
    while a < b && is_ws_byte(*(s.data + a)) { a++; }
    while b > a && is_ws_byte(*(s.data + b - 1)) { b--; }
    str sub;
    sub.data = s.data + a;
    sub.len = b - a;
    Value r = new_str(vm, sub);
    gc_root_reset(&vm.heap, rm);
    return r;
}

private Value nat_str_split(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    i32 rm = gc_root_mark(&vm.heap);
    Value sv2 = js_to_string_value(vm, thisv);
    gc_root(&vm.heap, sv2);
    str s = sview(sv2);
    JsObject* arr = js_new_array(&vm.heap, vm.array_proto);
    gc_root(&vm.heap, value_cell(&arr.head));
    Value sepv = arg_at(args, argc, 0);
    if value_is_undefined(sepv) {
        js_array_set(arr, 0, sv2);
        gc_root_reset(&vm.heap, rm);
        return value_cell(&arr.head);
    }
    Value sepsv = js_to_string_value(vm, sepv);
    gc_root(&vm.heap, sepsv);
    str sep = sview(sepsv);
    i32 limit = -1;
    if argc > 1 && !value_is_undefined(*(args + 1)) {
        limit = to_int_arg(*(args + 1));
        if limit < 0 { limit = 0; }
    }
    i32 n = 0;
    if sep.len == 0 {
        // split into UTF-16 code units
        i32 ulen = value_as_string(sv2).u16len;
        for i32 i = 0; i < ulen; i++ {
            if limit >= 0 && n >= limit { break; }
            js_array_set(arr, n, str_u16_range(vm, sv2, i, i + 1));
            n++;
        }
    } else {
        i32 at = 0;
        bool capped = false;
        while true {
            if limit >= 0 && n >= limit { capped = true; break; }
            i32 f = str_find_from(s, sep, at);
            if f < 0 { break; }
            str part;
            part.data = s.data + at;
            part.len = f - at;
            js_array_set(arr, n, new_str(vm, part));
            n++;
            at = f + sep.len;
        }
        if !capped && (limit < 0 || n < limit) {
            str tail;
            tail.data = s.data + at;
            tail.len = s.len - at;
            js_array_set(arr, n, new_str(vm, tail));
        }
    }
    gc_root_reset(&vm.heap, rm);
    return value_cell(&arr.head);
}

private Value nat_str_repeat(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    i32 n = to_int_arg(arg_at(args, argc, 0));
    if n < 0 {
        vm_throw_error(vm, ERR_RANGE, "invalid repeat count");
        return value_undefined();
    }
    i32 rm = gc_root_mark(&vm.heap);
    Value sv2 = js_to_string_value(vm, thisv);
    gc_root(&vm.heap, sv2);
    str s = sview(sv2);
    str_buf sb;
    str_buf_init(&sb);
    for i32 i = 0; i < n; i++ {
        str_buf_add(&sb, s);
    }
    Value r = new_str(vm, str_buf_to_str(&sb));
    str_buf_free(&sb);
    gc_root_reset(&vm.heap, rm);
    return r;
}

private Value str_pad(VM* vm, Value thisv, Value* args, i32 argc, bool at_start) {
    i32 rm = gc_root_mark(&vm.heap);
    Value sv2 = js_to_string_value(vm, thisv);
    gc_root(&vm.heap, sv2);
    str s = sview(sv2);
    i32 src_u = value_as_string(sv2).u16len;
    i32 target = to_int_arg(arg_at(args, argc, 0));
    str pad = " ";
    if argc > 1 && !value_is_undefined(*(args + 1)) {
        Value pv = js_to_string_value(vm, *(args + 1));
        gc_root(&vm.heap, pv);
        pad = sview(pv);
    }
    if target <= src_u || pad.len == 0 {
        gc_root_reset(&vm.heap, rm);
        return sv2;
    }
    i32 pad_u = u16_count(pad);
    str_buf sb;
    str_buf_init(&sb);
    if !at_start { str_buf_add(&sb, s); }
    i32 need = target - src_u;   // code units to add
    while need > 0 {
        if need >= pad_u {
            str_buf_add(&sb, pad);
            need -= pad_u;
        } else {
            u16_slice_into(&sb, pad, 0, need);
            need = 0;
        }
    }
    if at_start { str_buf_add(&sb, s); }
    Value r = new_str(vm, str_buf_to_str(&sb));
    str_buf_free(&sb);
    gc_root_reset(&vm.heap, rm);
    return r;
}

private Value nat_str_padstart(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    return str_pad(as_vm(vmp), thisv, args, argc, true);
}

private Value nat_str_padend(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    return str_pad(as_vm(vmp), thisv, args, argc, false);
}

private Value str_replace_impl(VM* vm, Value thisv, Value* args, i32 argc, bool all) {
    i32 rm = gc_root_mark(&vm.heap);
    Value sv2 = js_to_string_value(vm, thisv);
    gc_root(&vm.heap, sv2);
    Value pv = js_to_string_value(vm, arg_at(args, argc, 0));
    gc_root(&vm.heap, pv);
    Value rv = arg_at(args, argc, 1);
    bool fn_repl = value_is_callable(rv);
    Value rsv = value_undefined();
    if !fn_repl {
        rsv = js_to_string_value(vm, rv);
        gc_root(&vm.heap, rsv);
    }
    str s = sview(sv2);
    str pat = sview(pv);
    str_buf sb;
    str_buf_init(&sb);
    i32 at = 0;
    while at <= s.len {
        i32 f = str_find_from(s, pat, at);
        if f < 0 || (pat.len == 0 && at > 0) { break; }
        str pre;
        pre.data = s.data + at;
        pre.len = f - at;
        str_buf_add(&sb, pre);
        if fn_repl {
            Value[1] cargs = { pv };
            Value fr = vm_call_value(vm, rv, value_undefined(), &cargs[0], 1);
            if vm.has_pending {
                str_buf_free(&sb);
                gc_root_reset(&vm.heap, rm);
                return value_undefined();
            }
            gc_root(&vm.heap, fr);
            Value frs = js_to_string_value(vm, fr);
            gc_root(&vm.heap, frs);
            str_buf_add(&sb, sview(frs));
        } else {
            str_buf_add(&sb, sview(rsv));
        }
        at = f + pat.len;
        if pat.len == 0 { break; }
        if !all { break; }
    }
    str tail;
    tail.data = s.data + at;
    tail.len = s.len - at;
    str_buf_add(&sb, tail);
    Value r = new_str(vm, str_buf_to_str(&sb));
    str_buf_free(&sb);
    gc_root_reset(&vm.heap, rm);
    return r;
}

private Value nat_str_replace(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    return str_replace_impl(as_vm(vmp), thisv, args, argc, false);
}

private Value nat_str_replaceall(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    return str_replace_impl(as_vm(vmp), thisv, args, argc, true);
}

private Value nat_str_tostring(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    return js_to_string_value(as_vm(vmp), thisv);
}

private Value nat_str_concat(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    i32 rm = gc_root_mark(&vm.heap);
    Value sv2 = js_to_string_value(vm, thisv);
    gc_root(&vm.heap, sv2);
    str_buf sb;
    str_buf_init(&sb);
    str_buf_add(&sb, sview(sv2));
    for i32 i = 0; i < argc; i++ {
        Value a = js_to_string_value(vm, *(args + i));
        gc_root(&vm.heap, a);
        str_buf_add(&sb, sview(a));
    }
    Value r = new_str(vm, str_buf_to_str(&sb));
    str_buf_free(&sb);
    gc_root_reset(&vm.heap, rm);
    return r;
}

private Value nat_str_at(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    i32 rm = gc_root_mark(&vm.heap);
    Value sv2 = js_to_string_value(vm, thisv);
    gc_root(&vm.heap, sv2);
    i32 ulen = value_as_string(sv2).u16len;
    i32 i = to_int_arg(arg_at(args, argc, 0));
    if i < 0 { i += ulen; }
    Value r;
    if i < 0 || i >= ulen {
        r = value_undefined();
    } else {
        r = str_u16_range(vm, sv2, i, i + 1);
    }
    gc_root_reset(&vm.heap, rm);
    return r;
}

private Value str_trim_side(VM* vm, Value thisv, bool left, bool right) {
    i32 rm = gc_root_mark(&vm.heap);
    Value sv2 = js_to_string_value(vm, thisv);
    gc_root(&vm.heap, sv2);
    str s = sview(sv2);
    i32 a = 0;
    i32 b = s.len;
    if left { while a < b && is_ws_byte(*(s.data + a)) { a++; } }
    if right { while b > a && is_ws_byte(*(s.data + b - 1)) { b--; } }
    str sub;
    sub.data = s.data + a;
    sub.len = b - a;
    Value r = new_str(vm, sub);
    gc_root_reset(&vm.heap, rm);
    return r;
}

private Value nat_str_trimstart(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    return str_trim_side(as_vm(vmp), thisv, true, false);
}
private Value nat_str_trimend(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    return str_trim_side(as_vm(vmp), thisv, false, true);
}

private Value nat_object_fromentries(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    JsObject* o = js_new_object(&vm.heap, vm.object_proto);
    i32 rm = gc_root_mark(&vm.heap);
    gc_root(&vm.heap, value_cell(&o.head));
    Value src = arg_at(args, argc, 0);
    if value_is_array(src) {
        JsObject* a = value_as_object(src);
        for i32 i = 0; i < a.elen; i++ {
            Value pair = js_array_get(a, i);
            if value_is_array(pair) {
                JsObject* p = value_as_object(pair);
                Value ks = js_to_string_value(vm, js_array_get(p, 0));
                vm_push(vm, ks);
                u32 atom = bi_atom(vm, sview(ks));
                vm_pop(vm);
                js_set_prop(o, atom, js_array_get(p, 1));
            }
        }
    } else if value_is_object(src) || value_is_map(src) || value_is_generator(src) {
        // any iterable of [key, value] entries (e.g. a Map)
        Value it;
        if vm_get_iterator(vm, src, &it) {
            gc_root(&vm.heap, it);
            while true {
                Value e;
                bool done;
                if !vm_iter_next(vm, it, &e, &done) { break; }
                if done { break; }
                if value_is_array(e) {
                    JsObject* p = value_as_object(e);
                    Value ks = js_to_string_value(vm, js_array_get(p, 0));
                    vm_push(vm, ks);
                    u32 atom = bi_atom(vm, sview(ks));
                    vm_pop(vm);
                    js_set_prop(o, atom, js_array_get(p, 1));
                }
            }
        }
    }
    gc_root_reset(&vm.heap, rm);
    return value_cell(&o.head);
}

private Value nat_object_is(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    return value_bool(js_same_value(arg_at(args, argc, 0), arg_at(args, argc, 1)));
}

private Value nat_object_hasown(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    Value ov = arg_at(args, argc, 0);
    if !value_is_object(ov) { return value_bool(false); }
    JsObject* o = value_as_object(ov);
    Value kv = arg_at(args, argc, 1);
    if (o.obj_flags & OBJF_ARRAY) != 0 && value_is_int(kv) {
        return value_bool(js_array_has(o, value_as_int(kv)));
    }
    i32 rm = gc_root_mark(&vm.heap);
    Value ks = js_to_string_value(vm, kv);
    gc_root(&vm.heap, ks);
    u32 a = bi_atom(vm, sview(ks));
    gc_root_reset(&vm.heap, rm);
    return value_bool(props_entry(&o.props, a) != null);
}

// --- Number / Boolean ------------------------------------------------------------

private Value nat_number_ctor(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    if argc == 0 { return value_int(0); }
    return js_number_value(js_to_number(*(args)));
}

private Value nat_boolean_ctor(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    return value_bool(js_truthy(arg_at(args, argc, 0)));
}

private Value nat_num_isinteger(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    Value v = arg_at(args, argc, 0);
    if !value_is_number(v) { return value_bool(false); }
    f64 d = js_to_number(v);
    return value_bool(d == d && cast(f64, cast(i64, d)) == d);
}

private Value nat_num_issafeinteger(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    Value v = arg_at(args, argc, 0);
    if !value_is_number(v) { return value_bool(false); }
    f64 d = js_to_number(v);
    if d != d { return value_bool(false); }
    if cast(f64, cast(i64, d)) != d { return value_bool(false); }
    return value_bool(d <= 9007199254740991.0 && d >= -9007199254740991.0);
}

private Value nat_num_isfinite(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    Value v = arg_at(args, argc, 0);
    if !value_is_number(v) { return value_bool(false); }
    f64 d = js_to_number(v);
    f64 inf = 1.0e308 * 10.0;
    return value_bool(d == d && d != inf && d != -inf);
}

private Value nat_num_isnan(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    Value v = arg_at(args, argc, 0);
    if !value_is_number(v) { return value_bool(false); }
    f64 d = js_to_number(v);
    return value_bool(d != d);
}

private Value nat_global_isnan(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    f64 d = js_to_number(arg_at(args, argc, 0));
    return value_bool(d != d);
}

private Value nat_global_isfinite(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    f64 d = js_to_number(arg_at(args, argc, 0));
    f64 inf = 1.0e308 * 10.0;
    return value_bool(d == d && d != inf && d != -inf);
}

private bool uri_unreserved(u8 c) {
    if c >= 'A' && c <= 'Z' { return true; }
    if c >= 'a' && c <= 'z' { return true; }
    if c >= '0' && c <= '9' { return true; }
    return c == '-' || c == '_' || c == '.' || c == '!' || c == '~'
        || c == '*' || c == '\'' || c == '(' || c == ')';
}

private bool uri_reserved(u8 c) {
    return c == ';' || c == ',' || c == '/' || c == '?' || c == ':'
        || c == '@' || c == '&' || c == '=' || c == '+' || c == '$' || c == '#';
}

// component=true is encodeURIComponent; false keeps reserved chars (encodeURI).
private Value uri_encode(VM* vm, Value thisv, Value* args, i32 argc, bool component) {
    i32 rm = gc_root_mark(&vm.heap);
    Value sv = js_to_string_value(vm, arg_at(args, argc, 0));
    gc_root(&vm.heap, sv);
    str s = sview(sv);
    str_buf sb;
    str_buf_init(&sb);
    str hex = "0123456789ABCDEF";
    for i32 i = 0; i < s.len; i++ {
        u8 c = *(s.data + i);
        if uri_unreserved(c) || (!component && uri_reserved(c)) {
            str one;
            one.data = s.data + i;
            one.len = 1;
            str_buf_add(&sb, one);
        } else {
            u8[3] esc;
            esc[0] = '%';
            esc[1] = *(hex.data + (c >> 4));
            esc[2] = *(hex.data + (c & 15));
            str e;
            e.data = &esc[0];
            e.len = 3;
            str_buf_add(&sb, e);
        }
    }
    Value r = new_str(vm, str_buf_to_str(&sb));
    str_buf_free(&sb);
    gc_root_reset(&vm.heap, rm);
    return r;
}

private i32 hex_val(u8 c) {
    if c >= '0' && c <= '9' { return c - '0'; }
    if c >= 'A' && c <= 'F' { return c - 'A' + 10; }
    if c >= 'a' && c <= 'f' { return c - 'a' + 10; }
    return -1;
}

private Value uri_decode(VM* vm, Value thisv, Value* args, i32 argc, bool component) {
    i32 rm = gc_root_mark(&vm.heap);
    Value sv = js_to_string_value(vm, arg_at(args, argc, 0));
    gc_root(&vm.heap, sv);
    str s = sview(sv);
    str_buf sb;
    str_buf_init(&sb);
    i32 i = 0;
    while i < s.len {
        u8 c = *(s.data + i);
        i32 hi = -1;
        i32 lo = -1;
        if c == '%' && i + 2 < s.len {
            hi = hex_val(*(s.data + i + 1));
            lo = hex_val(*(s.data + i + 2));
        }
        if hi >= 0 && lo >= 0 {
            u8 b = cast(u8, (hi << 4) | lo);
            // decodeURI leaves reserved-char escapes intact
            if !component && uri_reserved(b) {
                str keep;
                keep.data = s.data + i;
                keep.len = 3;
                str_buf_add(&sb, keep);
            } else {
                u8[1] bb;
                bb[0] = b;
                str one;
                one.data = &bb[0];
                one.len = 1;
                str_buf_add(&sb, one);
            }
            i += 3;
        } else {
            str one;
            one.data = s.data + i;
            one.len = 1;
            str_buf_add(&sb, one);
            i++;
        }
    }
    Value r = new_str(vm, str_buf_to_str(&sb));
    str_buf_free(&sb);
    gc_root_reset(&vm.heap, rm);
    return r;
}

private Value nat_encode_uri_comp(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    return uri_encode(as_vm(vmp), thisv, args, argc, true);
}
private Value nat_encode_uri(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    return uri_encode(as_vm(vmp), thisv, args, argc, false);
}
private Value nat_decode_uri_comp(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    return uri_decode(as_vm(vmp), thisv, args, argc, true);
}
private Value nat_decode_uri(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    return uri_decode(as_vm(vmp), thisv, args, argc, false);
}

// Deep clone for structuredClone. `keys`/`clones` map an original's
// identity to its clone so cycles and shared references are preserved.
private Value struct_clone(VM* vm, Value v, Vec<u64>* keys, Vec<Value>* clones) {
    if !value_is_cell(v) { return v; }        // int / double / bool / null / undefined
    if value_is_string(v) { return v; }       // immutable: share
    if value_is_symbol(v) || value_is_function(v) || value_is_native(v) {
        vm_throw_error(vm, ERR_TYPE, "could not be cloned");
        return value_undefined();
    }
    u64 id = v.bits;
    for i32 i = 0; i < keys.len; i++ {
        if vec_get(keys, i) == id { return vec_get(clones, i); }
    }
    if value_is_array(v) {
        JsObject* a = value_as_object(v);
        JsObject* r = js_new_array(&vm.heap, vm.array_proto);
        Value rv = value_cell(&r.head);
        gc_root(&vm.heap, rv);
        vec_push(keys, id);
        vec_push(clones, rv);
        js_array_set_length(r, a.elen);       // holes stay holes
        for i32 i = 0; i < a.elen; i++ {
            if !js_array_has(a, i) { continue; }
            Value cv = struct_clone(vm, js_array_get(a, i), keys, clones);
            if vm.has_pending { return value_undefined(); }
            js_array_set(r, i, cv);
        }
        return rv;
    }
    if value_is_map(v) {
        JsMap* m = value_as_map(v);
        JsMap* r = js_new_map(&vm.heap, m.is_set ? vm_set_proto(vm) : vm_map_proto(vm), m.is_set);
        Value rv = value_cell(&r.head);
        gc_root(&vm.heap, rv);
        vec_push(keys, id);
        vec_push(clones, rv);
        for i32 i = 0; i < m.len; i++ {
            if !*(m.live + i) { continue; }
            Value k = struct_clone(vm, *(m.keys + i), keys, clones);
            if vm.has_pending { return value_undefined(); }
            Value val = k;
            if !m.is_set {
                val = struct_clone(vm, *(m.vals + i), keys, clones);
                if vm.has_pending { return value_undefined(); }
            }
            map_put(r, k, val);
        }
        return rv;
    }
    if value_is_object(v) {
        JsObject* o = value_as_object(v);
        // Date: copy the internal timestamp into a fresh Date
        if props_get(&o.props, bi_atom(vm, "%t")) != null {
            Value ts;
            ignore js_get_prop(o, bi_atom(vm, "%t"), &ts);
            JsObject* d = js_new_object(&vm.heap, vm_date_proto(vm));
            js_set_prop(d, bi_atom(vm, "%t"), ts);
            Value dv = value_cell(&d.head);
            gc_root(&vm.heap, dv);
            vec_push(keys, id);
            vec_push(clones, dv);
            return dv;
        }
        JsObject* r = js_new_object(&vm.heap, vm.object_proto);
        Value rv = value_cell(&r.head);
        gc_root(&vm.heap, rv);
        vec_push(keys, id);
        vec_push(clones, rv);
        for i32 i = 0; i < o.props.len; i++ {
            if !prop_enumerable(vm, o.props.items + i) { continue; }
            u32 pk = (o.props.items + i).key;
            Value pv;
            if !vm_get_prop_value(vm, v, pk, &pv) { return value_undefined(); }
            Value cv = struct_clone(vm, pv, keys, clones);
            if vm.has_pending { return value_undefined(); }
            js_set_prop(r, pk, cv);
        }
        return rv;
    }
    return v;
}

private Value nat_structured_clone(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    i32 rm = gc_root_mark(&vm.heap);
    Value src = arg_at(args, argc, 0);
    gc_root(&vm.heap, src);
    Vec<u64> keys = vec_new<u64>(8);
    Vec<Value> clones = vec_new<Value>(8);
    Value r = struct_clone(vm, src, &keys, &clones);
    vec_free(&keys);
    vec_free(&clones);
    gc_root_reset(&vm.heap, rm);
    return r;
}

private Value nat_parseint(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    i32 rm = gc_root_mark(&vm.heap);
    Value sv2 = js_to_string_value(vm, arg_at(args, argc, 0));
    gc_root(&vm.heap, sv2);
    str s = sview(sv2);
    gc_root_reset(&vm.heap, rm);
    i32 radix = argc > 1 ? to_int_arg(*(args + 1)) : 0;
    i32 i = 0;
    while i < s.len && is_ws_byte(*(s.data + i)) { i++; }
    f64 sign = 1.0;
    if i < s.len && (*(s.data + i) == '+' || *(s.data + i) == '-') {
        if *(s.data + i) == '-' { sign = -1.0; }
        i++;
    }
    if radix == 0 {
        radix = 10;
        if i + 1 < s.len && *(s.data + i) == '0'
            && (*(s.data + i + 1) == 'x' || *(s.data + i + 1) == 'X') {
            radix = 16;
            i += 2;
        }
    } else if radix == 16 {
        if i + 1 < s.len && *(s.data + i) == '0'
            && (*(s.data + i + 1) == 'x' || *(s.data + i + 1) == 'X') {
            i += 2;
        }
    }
    if radix < 2 || radix > 36 { return value_number(0.0 / 0.0); }
    f64 v = 0.0;
    i32 n_digits = 0;
    while i < s.len {
        u8 c = *(s.data + i);
        i32 d = -1;
        if c >= '0' && c <= '9' { d = c - '0'; }
        else if c >= 'a' && c <= 'z' { d = c - 'a' + 10; }
        else if c >= 'A' && c <= 'Z' { d = c - 'A' + 10; }
        if d < 0 || d >= radix { break; }
        v = v * radix + d;
        n_digits++;
        i++;
    }
    if n_digits == 0 { return value_number(0.0 / 0.0); }
    return js_number_value(sign * v);
}

private Value nat_parsefloat(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    i32 rm = gc_root_mark(&vm.heap);
    Value sv2 = js_to_string_value(vm, arg_at(args, argc, 0));
    gc_root(&vm.heap, sv2);
    str s = sview(sv2);
    i32 i = 0;
    while i < s.len && is_ws_byte(*(s.data + i)) { i++; }
    i32 start = i;
    if i < s.len && (*(s.data + i) == '+' || *(s.data + i) == '-') { i++; }
    if i + 8 <= s.len && *(s.data + i) == 'I' {
        str inf;
        inf.data = s.data + i;
        inf.len = 8;
        if str_equal(inf, "Infinity") { i += 8; }
    } else {
        while i < s.len && *(s.data + i) >= '0' && *(s.data + i) <= '9' { i++; }
        if i < s.len && *(s.data + i) == '.' {
            i++;
            while i < s.len && *(s.data + i) >= '0' && *(s.data + i) <= '9' { i++; }
        }
        i32 before_exp = i;
        if i < s.len && (*(s.data + i) == 'e' || *(s.data + i) == 'E') {
            i++;
            if i < s.len && (*(s.data + i) == '+' || *(s.data + i) == '-') { i++; }
            i32 ed = 0;
            while i < s.len && *(s.data + i) >= '0' && *(s.data + i) <= '9' {
                i++;
                ed++;
            }
            if ed == 0 { i = before_exp; }
        }
    }
    str slice;
    slice.data = s.data + start;
    slice.len = i - start;
    gc_root_reset(&vm.heap, rm);
    if slice.len == 0 { return value_number(0.0 / 0.0); }
    return js_number_value(js_string_to_number(slice));
}

private Value nat_num_tofixed(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    f64 v = js_to_number(thisv);
    i32 d = to_int_arg(arg_at(args, argc, 0));
    if d < 0 { d = 0; }
    if d > 20 { d = 20; }
    f64 inf = 1.0e308 * 10.0;
    f64 av = fabs(v);
    if v != v || v == inf || v == -inf || av >= 1.0e15 {
        return js_to_string_value(vm, js_number_value(v));
    }
    f64 scale = pow(10.0, d);
    i64 scaled = cast(i64, floor(av * scale + 0.5));
    string digits = format("{}", scaled);
    str_buf sb;
    str_buf_init(&sb);
    if v < 0.0 && scaled != 0 { str_buf_add(&sb, "-"); }
    str dg = digits;
    if dg.len <= d {
        str_buf_add(&sb, "0.");
        for i32 i = dg.len; i < d; i++ {
            str_buf_add(&sb, "0");
        }
        str_buf_add(&sb, dg);
    } else {
        str ip;
        ip.data = dg.data;
        ip.len = dg.len - d;
        str_buf_add(&sb, ip);
        if d > 0 {
            str_buf_add(&sb, ".");
            str fp;
            fp.data = dg.data + dg.len - d;
            fp.len = d;
            str_buf_add(&sb, fp);
        }
    }
    Value r = new_str(vm, str_buf_to_str(&sb));
    str_buf_free(&sb);
    free(digits);
    return r;
}

private Value nat_num_tostring(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    i32 radix = argc > 0 && !value_is_undefined(*(args)) ? to_int_arg(*(args)) : 10;
    if radix == 10 {
        return js_to_string_value(vm, thisv);
    }
    if radix < 2 || radix > 36 {
        vm_throw_error(vm, ERR_RANGE, "radix must be between 2 and 36");
        return value_undefined();
    }
    // integer part only for non-decimal radixes
    f64 v = js_to_number(thisv);
    if v != v { return new_str(vm, "NaN"); }
    bool neg = v < 0.0;
    i64 iv = cast(i64, fabs(v));
    u8[80] buf;
    i32 n = 0;
    if iv == 0 {
        buf[n] = '0';
        n++;
    }
    while iv > 0 {
        i32 d = cast(i32, iv % radix);
        u8 c = 0;
        if d < 10 { c = cast(u8, d + '0'); } else { c = cast(u8, d - 10 + 'a'); }
        buf[n] = c;
        n++;
        iv = iv / radix;
    }
    str_buf sb;
    str_buf_init(&sb);
    if neg { str_buf_add(&sb, "-"); }
    for i32 i = n - 1; i >= 0; i-- {
        str one;
        one.data = &buf[i];
        one.len = 1;
        str_buf_add(&sb, one);
    }
    Value r = new_str(vm, str_buf_to_str(&sb));
    str_buf_free(&sb);
    return r;
}

// Fills digits[0..sig) with the `sig` most significant decimal digits
// of av (av > 0, finite), correctly rounded, and returns the base-10
// exponent of the leading digit. Digits beyond the 17 a double can
// carry are padded with '0'.
private i32 decimal_sig(f64 av, i32 sig, u8* digits) {
    i32 calc = sig;
    if calc > 17 { calc = 17; }
    i32 e = cast(i32, floor(log10(av)));
    f64 p = pow(10.0, cast(f64, calc - 1 - e));
    i64 scaled = cast(i64, floor(av * p + 0.5));
    i64 lo = 1;
    for i32 i = 0; i < calc - 1; i++ { lo = lo * 10; }
    i64 hi = lo * 10;
    // correct off-by-one from log10 rounding at the boundaries
    i32 guard = 0;
    while scaled >= hi && guard < 4 {
        e++;
        p = pow(10.0, cast(f64, calc - 1 - e));
        scaled = cast(i64, floor(av * p + 0.5));
        guard++;
    }
    guard = 0;
    while scaled < lo && scaled > 0 && guard < 4 {
        e--;
        p = pow(10.0, cast(f64, calc - 1 - e));
        scaled = cast(i64, floor(av * p + 0.5));
        guard++;
    }
    string ds = format("{}", scaled);
    str s = ds;
    i32 n = s.len;
    for i32 i = 0; i < calc; i++ {
        digits[i] = i < n ? *(s.data + i) : cast(u8, '0');
    }
    for i32 i = calc; i < sig; i++ { digits[i] = '0'; }
    free(ds);
    return e;
}

private Value nat_num_valueof(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    return js_number_value(js_to_number(thisv));
}

private Value nat_num_toexponential(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    f64 v = js_to_number(thisv);
    f64 inf = 1.0e308 * 10.0;
    if v != v { return new_str(vm, "NaN"); }
    if v == inf { return new_str(vm, "Infinity"); }
    if v == -inf { return new_str(vm, "-Infinity"); }
    bool neg = v < 0.0;
    f64 av = neg ? -v : v;
    Value fdv = arg_at(args, argc, 0);
    bool have_f = !value_is_undefined(fdv);
    i32 f = have_f ? to_int_arg(fdv) : 6;
    if f < 0 { f = 0; }
    if f > 100 { f = 100; }
    i32 sig = f + 1;
    u8[128] digits;
    i32 e = 0;
    if av == 0.0 {
        for i32 i = 0; i < sig; i++ { digits[i] = '0'; }
    } else {
        e = decimal_sig(av, sig, &digits[0]);
    }
    i32 nd = sig;
    if !have_f {
        while nd > 1 && digits[nd - 1] == '0' { nd--; }
    }
    str_buf sb;
    str_buf_init(&sb);
    if neg { str_buf_add(&sb, "-"); }
    str d0;
    d0.data = &digits[0];
    d0.len = 1;
    str_buf_add(&sb, d0);
    if nd > 1 {
        str_buf_add(&sb, ".");
        str rest;
        rest.data = &digits[1];
        rest.len = nd - 1;
        str_buf_add(&sb, rest);
    }
    str_buf_add(&sb, "e");
    if e >= 0 { str_buf_add(&sb, "+"); } else { str_buf_add(&sb, "-"); }
    i32 ae = e < 0 ? -e : e;
    string es = format("{}", ae);
    str_buf_add(&sb, es);
    free(es);
    Value r = new_str(vm, str_buf_to_str(&sb));
    str_buf_free(&sb);
    return r;
}

private Value nat_num_toprecision(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    Value pv = arg_at(args, argc, 0);
    if value_is_undefined(pv) { return js_to_string_value(vm, thisv); }
    f64 v = js_to_number(thisv);
    f64 inf = 1.0e308 * 10.0;
    if v != v { return new_str(vm, "NaN"); }
    if v == inf { return new_str(vm, "Infinity"); }
    if v == -inf { return new_str(vm, "-Infinity"); }
    i32 p = to_int_arg(pv);
    if p < 1 { p = 1; }
    if p > 100 { p = 100; }
    bool neg = v < 0.0;
    f64 av = neg ? -v : v;
    u8[128] digits;
    i32 e = 0;
    if av == 0.0 {
        for i32 i = 0; i < p; i++ { digits[i] = '0'; }
    } else {
        e = decimal_sig(av, p, &digits[0]);
    }
    str_buf sb;
    str_buf_init(&sb);
    if neg { str_buf_add(&sb, "-"); }
    if e < -6 || e >= p {
        str d0;
        d0.data = &digits[0];
        d0.len = 1;
        str_buf_add(&sb, d0);
        if p > 1 {
            str_buf_add(&sb, ".");
            str rest;
            rest.data = &digits[1];
            rest.len = p - 1;
            str_buf_add(&sb, rest);
        }
        str_buf_add(&sb, "e");
        if e >= 0 { str_buf_add(&sb, "+"); } else { str_buf_add(&sb, "-"); }
        i32 ae = e < 0 ? -e : e;
        string es = format("{}", ae);
        str_buf_add(&sb, es);
        free(es);
    } else if e >= 0 {
        i32 ip = e + 1;
        str head;
        head.data = &digits[0];
        head.len = ip;
        str_buf_add(&sb, head);
        if ip < p {
            str_buf_add(&sb, ".");
            str tail;
            tail.data = &digits[ip];
            tail.len = p - ip;
            str_buf_add(&sb, tail);
        }
    } else {
        str_buf_add(&sb, "0.");
        for i32 i = 0; i < -e - 1; i++ { str_buf_add(&sb, "0"); }
        str all;
        all.data = &digits[0];
        all.len = p;
        str_buf_add(&sb, all);
    }
    Value r = new_str(vm, str_buf_to_str(&sb));
    str_buf_free(&sb);
    return r;
}

// Basic en-US locale: thousands grouping, up to 3 fraction digits.
private Value nat_num_tolocalestring(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    f64 v = js_to_number(thisv);
    f64 inf = 1.0e308 * 10.0;
    if v != v { return new_str(vm, "NaN"); }
    if v == inf { return new_str(vm, "\xe2\x88\x9e"); }
    if v == -inf { return new_str(vm, "-\xe2\x88\x9e"); }
    bool neg = v < 0.0;
    f64 av = neg ? -v : v;
    if av >= 9.0e18 { return js_to_string_value(vm, thisv); }
    i64 ipart = 0;
    i32 frac = 0;
    if av >= 1.0e15 {
        ipart = cast(i64, av);
    } else {
        i64 iscaled = cast(i64, floor(av * 1000.0 + 0.5));
        ipart = iscaled / 1000;
        frac = cast(i32, iscaled % 1000);
    }
    string ips = format("{}", ipart);
    str s = ips;
    str_buf sb;
    str_buf_init(&sb);
    if neg && (ipart != 0 || frac != 0) { str_buf_add(&sb, "-"); }
    i32 nlen = s.len;
    for i32 i = 0; i < nlen; i++ {
        if i > 0 && ((nlen - i) % 3) == 0 { str_buf_add(&sb, ","); }
        str c;
        c.data = &s.data[i];
        c.len = 1;
        str_buf_add(&sb, c);
    }
    free(ips);
    if frac != 0 {
        u8[3] fb;
        fb[0] = cast(u8, '0' + (frac / 100));
        fb[1] = cast(u8, '0' + ((frac / 10) % 10));
        fb[2] = cast(u8, '0' + (frac % 10));
        i32 fl = 3;
        while fl > 0 && fb[fl - 1] == '0' { fl--; }
        str_buf_add(&sb, ".");
        str fs;
        fs.data = &fb[0];
        fs.len = fl;
        str_buf_add(&sb, fs);
    }
    Value r = new_str(vm, str_buf_to_str(&sb));
    str_buf_free(&sb);
    return r;
}

// --- Math ---------------------------------------------------------------------------

private Value math1(f64 v) {
    return js_number_value(v);
}

private Value nat_math_floor(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    return math1(floor(js_to_number(arg_at(args, argc, 0))));
}
private Value nat_math_ceil(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    return math1(ceil(js_to_number(arg_at(args, argc, 0))));
}
private Value nat_math_round(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    // JS rounds half toward +inf; -0.5..-0 round to -0
    f64 v = js_to_number(arg_at(args, argc, 0));
    f64 r = floor(v + 0.5);
    if r == 0.0 && v < 0.0 { return value_number(-0.0); }
    return math1(r);
}
private Value nat_math_trunc(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    f64 v = js_to_number(arg_at(args, argc, 0));
    return math1(v < 0.0 ? ceil(v) : floor(v));
}
private Value nat_math_abs(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    return math1(fabs(js_to_number(arg_at(args, argc, 0))));
}
private Value nat_math_sign(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    f64 v = js_to_number(arg_at(args, argc, 0));
    if v != v { return value_number(v); }
    if v > 0.0 { return value_int(1); }
    if v < 0.0 { return value_int(-1); }
    return js_number_value(v);
}
private Value nat_math_sqrt(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    return math1(sqrt(js_to_number(arg_at(args, argc, 0))));
}
private Value nat_math_cbrt(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    f64 v = js_to_number(arg_at(args, argc, 0));
    if v < 0.0 { return math1(-pow(-v, 1.0 / 3.0)); }
    return math1(pow(v, 1.0 / 3.0));
}
private Value nat_math_pow(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    return math1(pow(js_to_number(arg_at(args, argc, 0)), js_to_number(arg_at(args, argc, 1))));
}
private Value nat_math_exp(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    return math1(exp(js_to_number(arg_at(args, argc, 0))));
}
private Value nat_math_log(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    return math1(log(js_to_number(arg_at(args, argc, 0))));
}
private Value nat_math_log2(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    return math1(log2(js_to_number(arg_at(args, argc, 0))));
}
private Value nat_math_log10(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    return math1(log10(js_to_number(arg_at(args, argc, 0))));
}
private Value nat_math_sin(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    return math1(sin(js_to_number(arg_at(args, argc, 0))));
}
private Value nat_math_cos(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    return math1(cos(js_to_number(arg_at(args, argc, 0))));
}
private Value nat_math_tan(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    return math1(tan(js_to_number(arg_at(args, argc, 0))));
}
private Value nat_math_asin(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    return math1(asin(js_to_number(arg_at(args, argc, 0))));
}
private Value nat_math_acos(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    return math1(acos(js_to_number(arg_at(args, argc, 0))));
}
private Value nat_math_atan(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    return math1(atan(js_to_number(arg_at(args, argc, 0))));
}
private Value nat_math_atan2(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    return math1(atan2(js_to_number(arg_at(args, argc, 0)), js_to_number(arg_at(args, argc, 1))));
}
private Value nat_math_hypot(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    f64 sum = 0.0;
    for i32 i = 0; i < argc; i++ {
        f64 v = js_to_number(*(args + i));
        sum += v * v;
    }
    return math1(sqrt(sum));
}
private Value nat_math_sinh(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    return math1(sinh(js_to_number(arg_at(args, argc, 0))));
}
private Value nat_math_cosh(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    return math1(cosh(js_to_number(arg_at(args, argc, 0))));
}
private Value nat_math_tanh(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    return math1(tanh(js_to_number(arg_at(args, argc, 0))));
}
private Value nat_math_asinh(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    return math1(asinh(js_to_number(arg_at(args, argc, 0))));
}
private Value nat_math_acosh(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    return math1(acosh(js_to_number(arg_at(args, argc, 0))));
}
private Value nat_math_atanh(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    return math1(atanh(js_to_number(arg_at(args, argc, 0))));
}
private Value nat_math_log1p(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    return math1(log1p(js_to_number(arg_at(args, argc, 0))));
}
private Value nat_math_expm1(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    return math1(expm1(js_to_number(arg_at(args, argc, 0))));
}
private Value nat_math_fround(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    f64 v = js_to_number(arg_at(args, argc, 0));
    return math1(cast(f64, cast(f32, v)));
}
private Value nat_math_imul(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    f64 a = js_to_number(arg_at(args, argc, 0));
    f64 b = js_to_number(arg_at(args, argc, 1));
    i32 ai = a != a ? 0 : cast(i32, cast(i64, a));
    i32 bi = b != b ? 0 : cast(i32, cast(i64, b));
    i32 r = cast(i32, cast(i64, ai) * cast(i64, bi));
    return value_int(r);
}
private Value nat_math_clz32(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    f64 v = js_to_number(arg_at(args, argc, 0));
    u32 u = v != v ? 0 : cast(u32, cast(i32, cast(i64, v)));
    if u == 0 { return value_int(32); }
    i32 n = 0;
    while (u & 0x80000000) == 0 {
        n++;
        u = u << 1;
    }
    return value_int(n);
}

private Value nat_math_min(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    f64 best = 1.0e308 * 10.0;
    for i32 i = 0; i < argc; i++ {
        f64 v = js_to_number(*(args + i));
        if v != v { return value_number(v); }
        if v < best { best = v; }
    }
    return js_number_value(best);
}

private Value nat_math_max(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    f64 best = -(1.0e308 * 10.0);
    for i32 i = 0; i < argc; i++ {
        f64 v = js_to_number(*(args + i));
        if v != v { return value_number(v); }
        if v > best { best = v; }
    }
    return js_number_value(best);
}

private Value nat_math_random(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    u64 x = vm.rng;
    x = x ^ (x << 13);
    x = x ^ (x >> 7);
    x = x ^ (x << 17);
    vm.rng = x;
    f64 r = cast(f64, x >> 11) * (1.0 / 9007199254740992.0);
    return value_number(r);
}

// --- JSON -----------------------------------------------------------------------------

private void json_escape_into(str_buf* sb, str s) {
    str_buf_add(sb, "\"");
    for i32 i = 0; i < s.len; i++ {
        u8 c = *(s.data + i);
        if c == '"' { str_buf_add(sb, "\\\""); }
        else if c == '\\' { str_buf_add(sb, "\\\\"); }
        else if c == '\n' { str_buf_add(sb, "\\n"); }
        else if c == '\r' { str_buf_add(sb, "\\r"); }
        else if c == '\t' { str_buf_add(sb, "\\t"); }
        else if c == 8 { str_buf_add(sb, "\\b"); }
        else if c == 12 { str_buf_add(sb, "\\f"); }
        else if c < 0x20 {
            str_buf_add(sb, "\\u00");
            u8[2] hex;
            u8 hi = cast(u8, c >> 4);
            u8 lo = c & 15;
            hex[0] = hi < 10 ? cast(u8, hi + '0') : cast(u8, hi - 10 + 'a');
            hex[1] = lo < 10 ? cast(u8, lo + '0') : cast(u8, lo - 10 + 'a');
            str h;
            h.data = &hex[0];
            h.len = 2;
            str_buf_add(sb, h);
        } else {
            str one;
            one.data = s.data + i;
            one.len = 1;
            str_buf_add(sb, one);
        }
    }
    str_buf_add(sb, "\"");
}

private void json_indent_into(str_buf* sb, str gap, i32 depth) {
    if gap.len == 0 { return; }
    str_buf_add(sb, "\n");
    for i32 i = 0; i < depth; i++ {
        str_buf_add(sb, gap);
    }
}

// Returns false when the value is unrepresentable (undefined/function).
// gap is the per-level indent string; empty means compact.
// Serialization state shared across the recursion: the optional
// replacer function, the optional array-replacer allowlist of keys,
// the indent gap, and the circular-reference guard.
struct JsonCtx {
    Value replacer;    // callable, else undefined
    Vec<u32>* allow;   // atom keys, else null (array replacer)
    str gap;
    Vec<u64>* seen;
}

// Applies toJSON(key) then the replacer function to holder[key] = v,
// returning the value to actually serialize.
private Value json_transform(VM* vm, JsonCtx* ctx, Value holder, str key, Value v) {
    if value_is_object(v) || value_is_map(v) {
        Value tj;
        if vm_get_prop_value(vm, v, atom_intern(&vm.atoms, "toJSON"), &tj) {
            if value_is_callable(tj) {
                GcString* kg = gc_new_string(&vm.heap, key);
                Value ks = value_cell(&kg.head);
                gc_root(&vm.heap, ks);
                v = vm_call_value(vm, tj, v, &ks, 1);
                if vm.has_pending { return v; }
            }
        }
        if vm.has_pending { return v; }
    }
    if value_is_callable(ctx.replacer) {
        GcString* kg = gc_new_string(&vm.heap, key);
        Value[2] a;
        a[0] = value_cell(&kg.head);
        a[1] = v;
        gc_root(&vm.heap, a[0]);
        v = vm_call_value(vm, ctx.replacer, holder, &a[0], 2);
    }
    return v;
}

private bool json_write(VM* vm, str_buf* sb, Value v, JsonCtx* ctx, i32 depth) {
    str gap = ctx.gap;
    if value_is_undefined(v) || value_is_callable(v) || value_is_hole(v) {
        return false;
    }
    if value_is_null(v) {
        str_buf_add(sb, "null");
        return true;
    }
    if value_is_bool(v) {
        str_buf_add(sb, value_is_true(v) ? "true" : "false");
        return true;
    }
    if value_is_number(v) {
        f64 d = js_to_number(v);
        f64 inf = 1.0e308 * 10.0;
        if d != d || d == inf || d == -inf {
            str_buf_add(sb, "null");
            return true;
        }
        i32 rm = gc_root_mark(&vm.heap);
        Value ns = js_to_string_value(vm, v);
        gc_root(&vm.heap, ns);
        str_buf_add(sb, sview(ns));
        gc_root_reset(&vm.heap, rm);
        return true;
    }
    if value_is_string(v) {
        json_escape_into(sb, sview(v));
        return true;
    }
    if !value_is_object(v) { return false; }
    JsObject* o = value_as_object(v);
    Vec<u64>* seen = ctx.seen;
    u64 pid = v.bits;
    for i32 i = 0; i < seen.len; i++ {
        if vec_get(seen, i) == pid {
            vm_throw_error(vm, ERR_TYPE, "converting circular structure to JSON");
            return false;
        }
    }
    vec_push(seen, pid);
    if (o.obj_flags & OBJF_ARRAY) != 0 {
        str_buf_add(sb, "[");
        for i32 i = 0; i < o.elen; i++ {
            if i > 0 { str_buf_add(sb, ","); }
            json_indent_into(sb, gap, depth + 1);
            i32 rm = gc_root_mark(&vm.heap);
            string ks = format("{}", i);
            Value child = json_transform(vm, ctx, v, ks, js_array_get(o, i));
            free(ks);
            gc_root(&vm.heap, child);
            bool wrote = json_write(vm, sb, child, ctx, depth + 1);
            gc_root_reset(&vm.heap, rm);
            if !wrote {
                if vm.has_pending {
                    ignore vec_pop(seen);
                    return false;
                }
                str_buf_add(sb, "null");
            }
        }
        if o.elen > 0 { json_indent_into(sb, gap, depth); }
        str_buf_add(sb, "]");
    } else {
        str_buf_add(sb, "{");
        bool first = true;
        // array replacer restricts (and orders) keys; otherwise own order
        i32 count = ctx.allow != null ? ctx.allow.len : o.props.len;
        for i32 i = 0; i < count; i++ {
            u32 key = 0;
            if ctx.allow != null {
                key = vec_get(ctx.allow, i);
            } else {
                key = (o.props.items + i).key;
                if !prop_enumerable(vm, o.props.items + i) { continue; }
            }
            Value pval;
            if !vm_get_prop_value(vm, v, key, &pval) {
                ignore vec_pop(seen);
                return false;
            }
            i32 rm = gc_root_mark(&vm.heap);
            Value cval = json_transform(vm, ctx, v, atom_name(&vm.atoms, key), pval);
            gc_root(&vm.heap, cval);
            if value_is_undefined(cval) || value_is_callable(cval) {
                gc_root_reset(&vm.heap, rm);
                if vm.has_pending { ignore vec_pop(seen); return false; }
                continue;
            }
            str_buf sub;
            str_buf_init(&sub);
            bool wrote = json_write(vm, &sub, cval, ctx, depth + 1);
            gc_root_reset(&vm.heap, rm);
            if !wrote {
                str_buf_free(&sub);
                if vm.has_pending {
                    ignore vec_pop(seen);
                    return false;
                }
                continue;
            }
            if !first { str_buf_add(sb, ","); }
            json_indent_into(sb, gap, depth + 1);
            json_escape_into(sb, atom_name(&vm.atoms, key));
            str_buf_add(sb, gap.len > 0 ? ": " : ":");
            str_buf_add(sb, str_buf_to_str(&sub));
            str_buf_free(&sub);
            first = false;
        }
        if !first { json_indent_into(sb, gap, depth); }
        str_buf_add(sb, "}");
    }
    ignore vec_pop(seen);
    return true;
}

private Value nat_json_stringify(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    Value v = arg_at(args, argc, 0);
    i32 rm = gc_root_mark(&vm.heap);
    gc_root(&vm.heap, v);

    // replacer: a function transforms values, an array allowlists keys
    Value replacer = arg_at(args, argc, 1);
    JsonCtx ctx;
    ctx.replacer = value_undefined();
    ctx.allow = null;
    Vec<u32> allow;
    bool have_allow = false;
    if value_is_callable(replacer) {
        ctx.replacer = replacer;
    } else if value_is_array(replacer) {
        allow = vec_new<u32>(8);
        have_allow = true;
        JsObject* ra = value_as_object(replacer);
        for i32 i = 0; i < ra.elen; i++ {
            Value e = js_array_get(ra, i);
            bool ok = value_is_string(e) || value_is_number(e);
            if ok {
                i32 krm = gc_root_mark(&vm.heap);
                Value kv = value_is_string(e) ? e : js_to_string_value(vm, e);
                gc_root(&vm.heap, kv);
                u32 a = atom_intern(&vm.atoms, sview(kv));
                gc_root_reset(&vm.heap, krm);
                bool dup = false;
                for i32 j = 0; j < allow.len; j++ {
                    if vec_get(&allow, j) == a { dup = true; break; }
                }
                if !dup { vec_push(&allow, a); }
            }
        }
        ctx.allow = &allow;
    }

    // the space argument: a number of spaces or a literal string (<=10)
    str gap;
    gap.data = null;
    gap.len = 0;
    u8[10] spaces;
    Value spacev = arg_at(args, argc, 2);
    if value_is_number(spacev) {
        i32 n = to_int_arg(spacev);
        if n > 10 { n = 10; }
        for i32 i = 0; i < n; i++ { spaces[i] = ' '; }
        gap.data = &spaces[0];
        gap.len = n < 0 ? 0 : n;
    } else if value_is_string(spacev) {
        gap = sview(spacev);
        if gap.len > 10 { gap.len = 10; }
    }
    ctx.gap = gap;

    Vec<u64> seen = vec_new<u64>(8);
    ctx.seen = &seen;

    // root wrapper { "": value } so toJSON/replacer see the top value
    JsObject* wrapper = js_new_object(&vm.heap, vm.object_proto);
    Value wrapv = value_cell(&wrapper.head);
    gc_root(&vm.heap, wrapv);
    js_set_prop(wrapper, atom_intern(&vm.atoms, ""), v);
    Value root = json_transform(vm, &ctx, wrapv, "", v);
    gc_root(&vm.heap, root);

    str_buf sb;
    str_buf_init(&sb);
    bool ok = !vm.has_pending && json_write(vm, &sb, root, &ctx, 0);
    vec_free(&seen);
    if have_allow { vec_free(&allow); }
    if !ok {
        str_buf_free(&sb);
        gc_root_reset(&vm.heap, rm);
        return value_undefined();
    }
    Value r = new_str(vm, str_buf_to_str(&sb));
    str_buf_free(&sb);
    gc_root_reset(&vm.heap, rm);
    return r;
}

struct JsonParser {
    str s;
    i32 pos;
    bool failed;
}

private void json_ws(JsonParser* p) {
    while p.pos < p.s.len {
        u8 c = *(p.s.data + p.pos);
        if c == ' ' || c == '\t' || c == '\n' || c == '\r' {
            p.pos++;
        } else {
            break;
        }
    }
}

private Value json_parse_value(VM* vm, JsonParser* p) {
    json_ws(p);
    if p.pos >= p.s.len {
        p.failed = true;
        return value_undefined();
    }
    u8 c = *(p.s.data + p.pos);
    if c == 'n' && p.pos + 4 <= p.s.len {
        p.pos += 4;
        return value_null();
    }
    if c == 't' && p.pos + 4 <= p.s.len {
        p.pos += 4;
        return value_bool(true);
    }
    if c == 'f' && p.pos + 5 <= p.s.len {
        p.pos += 5;
        return value_bool(false);
    }
    if c == '"' {
        p.pos++;
        str_buf sb;
        str_buf_init(&sb);
        while p.pos < p.s.len {
            u8 d = *(p.s.data + p.pos);
            if d == '"' { break; }
            if d == '\\' && p.pos + 1 < p.s.len {
                p.pos++;
                u8 e = *(p.s.data + p.pos);
                if e == 'n' { str_buf_add(&sb, "\n"); }
                else if e == 't' { str_buf_add(&sb, "\t"); }
                else if e == 'r' { str_buf_add(&sb, "\r"); }
                else if e == 'b' {
                    u8[1] bb;
                    bb[0] = 8;
                    str one;
                    one.data = &bb[0];
                    one.len = 1;
                    str_buf_add(&sb, one);
                }
                else if e == 'f' {
                    u8[1] bb;
                    bb[0] = 12;
                    str one;
                    one.data = &bb[0];
                    one.len = 1;
                    str_buf_add(&sb, one);
                }
                else if e == 'u' && p.pos + 4 < p.s.len {
                    u32 cp = 0;
                    for i32 k = 1; k <= 4; k++ {
                        u8 h = *(p.s.data + p.pos + k);
                        i32 hv = -1;
                        if h >= '0' && h <= '9' { hv = h - '0'; }
                        else if h >= 'a' && h <= 'f' { hv = h - 'a' + 10; }
                        else if h >= 'A' && h <= 'F' { hv = h - 'A' + 10; }
                        if hv < 0 {
                            p.failed = true;
                            hv = 0;
                        }
                        cp = cp * 16 + cast(u32, hv);
                    }
                    p.pos += 4;
                    u8[4] enc;
                    i32 n = bi_utf8_encode(&enc[0], cp);
                    str es;
                    es.data = &enc[0];
                    es.len = n;
                    str_buf_add(&sb, es);
                }
                else {
                    str one;
                    one.data = p.s.data + p.pos;
                    one.len = 1;
                    str_buf_add(&sb, one);
                }
                p.pos++;
                continue;
            }
            str one;
            one.data = p.s.data + p.pos;
            one.len = 1;
            str_buf_add(&sb, one);
            p.pos++;
        }
        if p.pos >= p.s.len {
            p.failed = true;
            str_buf_free(&sb);
            return value_undefined();
        }
        p.pos++;
        Value r = new_str(vm, str_buf_to_str(&sb));
        str_buf_free(&sb);
        return r;
    }
    if c == '[' {
        p.pos++;
        JsObject* arr = js_new_array(&vm.heap, vm.array_proto);
        i32 rm = gc_root_mark(&vm.heap);
        gc_root(&vm.heap, value_cell(&arr.head));
        json_ws(p);
        i32 n = 0;
        if p.pos < p.s.len && *(p.s.data + p.pos) == ']' {
            p.pos++;
        } else {
            while !p.failed {
                Value e = json_parse_value(vm, p);
                if p.failed { break; }
                js_array_set(arr, n, e);
                n++;
                json_ws(p);
                if p.pos < p.s.len && *(p.s.data + p.pos) == ',' {
                    p.pos++;
                    continue;
                }
                if p.pos < p.s.len && *(p.s.data + p.pos) == ']' {
                    p.pos++;
                    break;
                }
                p.failed = true;
            }
        }
        gc_root_reset(&vm.heap, rm);
        return value_cell(&arr.head);
    }
    if c == '{' {
        p.pos++;
        JsObject* obj = js_new_object(&vm.heap, vm.object_proto);
        i32 rm = gc_root_mark(&vm.heap);
        gc_root(&vm.heap, value_cell(&obj.head));
        json_ws(p);
        if p.pos < p.s.len && *(p.s.data + p.pos) == '}' {
            p.pos++;
        } else {
            while !p.failed {
                json_ws(p);
                Value key = json_parse_value(vm, p);
                if p.failed { break; }
                if !value_is_string(key) {
                    p.failed = true;
                    break;
                }
                gc_root(&vm.heap, key);
                json_ws(p);
                if p.pos >= p.s.len || *(p.s.data + p.pos) != ':' {
                    p.failed = true;
                    break;
                }
                p.pos++;
                Value val = json_parse_value(vm, p);
                if p.failed { break; }
                js_set_prop(obj, bi_atom(vm, sview(key)), val);
                json_ws(p);
                if p.pos < p.s.len && *(p.s.data + p.pos) == ',' {
                    p.pos++;
                    continue;
                }
                if p.pos < p.s.len && *(p.s.data + p.pos) == '}' {
                    p.pos++;
                    break;
                }
                p.failed = true;
            }
        }
        gc_root_reset(&vm.heap, rm);
        return value_cell(&obj.head);
    }
    // number
    i32 start = p.pos;
    if c == '-' { p.pos++; }
    while p.pos < p.s.len {
        u8 d = *(p.s.data + p.pos);
        if (d >= '0' && d <= '9') || d == '.' || d == 'e' || d == 'E' || d == '+' || d == '-' {
            p.pos++;
        } else {
            break;
        }
    }
    if p.pos == start {
        p.failed = true;
        return value_undefined();
    }
    str num;
    num.data = p.s.data + start;
    num.len = p.pos - start;
    f64 d2 = js_string_to_number(num);
    if d2 != d2 {
        p.failed = true;
        return value_undefined();
    }
    return js_number_value(d2);
}

private Value nat_json_parse(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    i32 rm = gc_root_mark(&vm.heap);
    Value sv2 = js_to_string_value(vm, arg_at(args, argc, 0));
    gc_root(&vm.heap, sv2);
    JsonParser p;
    p.s = sview(sv2);
    p.pos = 0;
    p.failed = false;
    Value r = json_parse_value(vm, &p);
    gc_root(&vm.heap, r);
    json_ws(&p);
    if p.failed || p.pos != p.s.len {
        gc_root_reset(&vm.heap, rm);
        vm_throw_error(vm, ERR_SYNTAX, "invalid JSON");
        return value_undefined();
    }
    gc_root_reset(&vm.heap, rm);
    return r;
}

// --- Function.prototype ------------------------------------------------------------------

private Value nat_fn_call(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    Value this_arg = arg_at(args, argc, 0);
    i32 rest = argc > 1 ? argc - 1 : 0;
    return vm_call_value(vm, thisv, this_arg, args + 1, rest);
}

private Value nat_fn_apply(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    Value this_arg = arg_at(args, argc, 0);
    Value arr = arg_at(args, argc, 1);
    if value_is_array(arr) {
        JsObject* a = value_as_object(arr);
        return vm_call_value(vm, thisv, this_arg, a.elems, a.elen);
    }
    return vm_call_value(vm, thisv, this_arg, args, 0);
}

// Entry for bound wrappers: state rides in the callee's env slots.
private Value nat_bound_entry(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    JsNative* me = value_as_native(callee);
    vm_push(vm, me.env0);
    vm_push(vm, me.env1);
    i32 total = 0;
    if value_is_array(me.env2) {
        JsObject* pre = value_as_object(me.env2);
        for i32 i = 0; i < pre.elen; i++ {
            vm_push(vm, js_array_get(pre, i));
            total++;
        }
    }
    for i32 i = 0; i < argc; i++ {
        vm_push(vm, *(args + i));
        total++;
    }
    return vm_call_stack(vm, total);
}

private Value nat_fn_bind(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    if !value_is_callable(thisv) {
        vm_throw_error(vm, ERR_TYPE, "bind receiver is not callable");
        return value_undefined();
    }
    JsObject* pre = js_new_array(&vm.heap, vm.array_proto);
    i32 rm = gc_root_mark(&vm.heap);
    gc_root(&vm.heap, value_cell(&pre.head));
    i32 n = argc > 1 ? argc - 1 : 0;
    for i32 i = 0; i < n; i++ {
        js_array_set(pre, i, *(args + 1 + i));
    }
    JsNative* w = js_new_native(&vm.heap, &nat_bound_entry, "bound");
    w.env0 = thisv;
    w.env1 = arg_at(args, argc, 0);
    w.env2 = value_cell(&pre.head);
    gc_root_reset(&vm.heap, rm);
    return value_cell(&w.head);
}

// --- console additions ----------------------------------------------------------------------

private Value console_write(VM* vm, Value* args, i32 argc, bool to_err) {
    for i32 i = 0; i < argc; i++ {
        if i > 0 {
            if to_err { eprint(" "); } else { print(" "); }
        }
        i32 rm = gc_root_mark(&vm.heap);
        Value s = js_console_string(vm, *(args + i));
        gc_root(&vm.heap, s);
        str view = sview(s);
        // lone surrogates can't go to a UTF-8 sink; show U+FFFD
        if wtf8_has_surrogate(view) {
            str_buf sb;
            str_buf_init(&sb);
            wtf8_sanitize_into(&sb, view);
            str clean = str_buf_to_str(&sb);
            if to_err { eprint("{}", clean); } else { print("{}", clean); }
            str_buf_free(&sb);
        } else {
            if to_err { eprint("{}", view); } else { print("{}", view); }
        }
        gc_root_reset(&vm.heap, rm);
    }
    if to_err { eprint("\n"); } else { print("\n"); }
    return value_undefined();
}

private Value nat_console_warn(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    return console_write(as_vm(vmp), args, argc, true);
}

private Value nat_console_info(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    return console_write(as_vm(vmp), args, argc, false);
}

// --- Errors ------------------------------------------------------------------------------------

private Value error_ctor_impl(VM* vm, Value thisv, Value* args, i32 argc, i32 kind) {
    JsObject* target = null;
    if value_is_object(thisv) {
        target = value_as_object(thisv);
    } else {
        target = js_new_object(&vm.heap, vm.error_protos[kind]);
    }
    i32 rm = gc_root_mark(&vm.heap);
    gc_root(&vm.heap, value_cell(&target.head));
    Value mv = arg_at(args, argc, 0);
    if !value_is_undefined(mv) {
        Value ms = js_to_string_value(vm, mv);
        js_set_prop(target, vm.atom_message, ms);
    }
    gc_root_reset(&vm.heap, rm);
    return value_cell(&target.head);
}

private Value nat_error_ctor(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    return error_ctor_impl(as_vm(vmp), thisv, args, argc, ERR_ERROR);
}
private Value nat_typeerror_ctor(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    return error_ctor_impl(as_vm(vmp), thisv, args, argc, ERR_TYPE);
}
private Value nat_rangeerror_ctor(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    return error_ctor_impl(as_vm(vmp), thisv, args, argc, ERR_RANGE);
}
private Value nat_referror_ctor(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    return error_ctor_impl(as_vm(vmp), thisv, args, argc, ERR_REF);
}
private Value nat_syntaxerror_ctor(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    return error_ctor_impl(as_vm(vmp), thisv, args, argc, ERR_SYNTAX);
}

private Value nat_error_tostring(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    if !value_is_object(thisv) { return new_str(vm, "Error"); }
    JsObject* o = value_as_object(thisv);
    Value nv = value_undefined();
    Value mv = value_undefined();
    ignore js_get_prop(o, vm.atom_name, &nv);
    ignore js_get_prop(o, vm.atom_message, &mv);
    i32 rm = gc_root_mark(&vm.heap);
    str name = "Error";
    if value_is_string(nv) { name = sview(nv); }
    str msg = "";
    if value_is_string(mv) { msg = sview(mv); }
    str_buf sb;
    str_buf_init(&sb);
    str_buf_add(&sb, name);
    if msg.len > 0 {
        str_buf_add(&sb, ": ");
        str_buf_add(&sb, msg);
    }
    Value r = new_str(vm, str_buf_to_str(&sb));
    str_buf_free(&sb);
    gc_root_reset(&vm.heap, rm);
    return r;
}

// --- Symbol -----------------------------------------------------------------------

private Value nat_symbol_ctor(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    Value desc = arg_at(args, argc, 0);
    if !value_is_undefined(desc) {
        desc = js_to_string_value(vm, desc);
    }
    return vm_new_symbol(vm, desc);
}

private Value nat_symbol_tostring(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    if !value_is_symbol(thisv) { return new_str(vm, "Symbol()"); }
    JsSymbol* sy = value_as_symbol(thisv);
    str_buf sb;
    str_buf_init(&sb);
    str_buf_add(&sb, "Symbol(");
    if value_is_string(sy.desc) { str_buf_add(&sb, sview(sy.desc)); }
    str_buf_add(&sb, ")");
    Value r = new_str(vm, str_buf_to_str(&sb));
    str_buf_free(&sb);
    return r;
}

private Value nat_symbol_valueof(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    return thisv;
}

// Symbol.prototype.description getter: the symbol's description or undefined.
private Value nat_symbol_description(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    if !value_is_symbol(thisv) { return value_undefined(); }
    return value_as_symbol(thisv).desc;
}

// --- array / string iterators ------------------------------------------------------

private Value nat_arr_iter_next(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    JsNative* me = value_as_native(callee);
    Value src = me.env0;
    i32 i = value_as_int(me.env1);
    JsObject* r = js_new_object(&vm.heap, vm.object_proto);
    vm_push(vm, value_cell(&r.head));
    i32 len = 0;
    if value_is_array(src) { len = value_as_object(src).elen; }
    else if value_is_string(src) { len = value_as_string(src).len; }
    if i >= len {
        js_set_prop(r, vm_atom(vm, "done"), value_bool(true));
        js_set_prop(r, vm_atom(vm, "value"), value_undefined());
    } else {
        me.env1 = value_int(i + 1);
        i32 kind = value_is_int(me.env2) ? value_as_int(me.env2) : 0;
        Value elem;
        if value_is_array(src) {
            elem = js_array_get(value_as_object(src), i);
        } else {
            // strings iterate by code point; `i` is a byte offset
            str view = gc_string_view(value_as_string(src));
            i32 n;
            ignore utf8_decode(view, i, &n);
            me.env1 = value_int(i + n);
            str one;
            one.data = view.data + i;
            one.len = n;
            elem = new_str(vm, one);
        }
        Value outv = elem;
        if kind == 1 {
            outv = value_int(i);
        } else if kind == 2 {
            vm_push(vm, elem);
            JsObject* pair = js_new_array(&vm.heap, vm.array_proto);
            vm_push(vm, value_cell(&pair.head));
            js_array_set(pair, 0, value_int(i));
            js_array_set(pair, 1, elem);
            outv = value_cell(&pair.head);
            vm.sp -= 2;
        }
        js_set_prop(r, vm_atom(vm, "done"), value_bool(false));
        js_set_prop(r, vm_atom(vm, "value"), outv);
    }
    return vm_pop_ret(vm, value_cell(&r.head));
}

private Value nat_return_this(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    return thisv;
}

private Value make_index_iterator(VM* vm, Value src, i32 kind) {
    i32 rm = gc_root_mark(&vm.heap);
    gc_root(&vm.heap, src);
    JsObject* it = js_new_object(&vm.heap, vm.object_proto);
    gc_root(&vm.heap, value_cell(&it.head));
    JsNative* nx = js_new_native(&vm.heap, &nat_arr_iter_next, "next");
    nx.env0 = src;
    nx.env1 = value_int(0);
    nx.env2 = value_int(kind);
    js_set_prop(it, vm_atom(vm, "next"), value_cell(&nx.head));
    // an iterator is itself iterable
    JsNative* si = js_new_native(&vm.heap, &nat_return_this, "[Symbol.iterator]");
    js_set_prop(it, vm_sym_iterator_id(vm), value_cell(&si.head));
    gc_root_reset(&vm.heap, rm);
    return value_cell(&it.head);
}

private Value nat_arr_symiter(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    return make_index_iterator(as_vm(vmp), thisv, 0);
}

private Value nat_arr_values(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    return make_index_iterator(as_vm(vmp), thisv, 0);
}

private Value nat_arr_keys(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    return make_index_iterator(as_vm(vmp), thisv, 1);
}

private Value nat_arr_entries(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    return make_index_iterator(as_vm(vmp), thisv, 2);
}

// --- generators ------------------------------------------------------------------------

private Value gen_result(VM* vm, Value val, bool done) {
    JsObject* r = js_new_object(&vm.heap, vm.object_proto);
    vm_push(vm, value_cell(&r.head));
    js_set_prop(r, vm_atom(vm, "value"), val);
    js_set_prop(r, vm_atom(vm, "done"), value_bool(done));
    return vm_pop_ret(vm, value_cell(&r.head));
}

private Value nat_gen_next(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    if !value_is_generator(thisv) {
        vm_throw_error(vm, ERR_TYPE, "next on a non-generator");
        return value_undefined();
    }
    JsGenerator* g = value_as_generator(thisv);
    if g.state == GEN_DONE {
        return gen_result(vm, value_undefined(), true);
    }
    vm_push(vm, thisv);
    Value res = vm_gen_resume(vm, g, arg_at(args, argc, 0), false);
    if vm.has_pending {
        vm_pop(vm);
        return value_undefined();
    }
    vm_push(vm, res);
    Value r = gen_result(vm, res, g.state == GEN_DONE);
    vm.sp -= 2;
    return r;
}

private Value nat_gen_return(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    if value_is_generator(thisv) {
        value_as_generator(thisv).state = GEN_DONE;
    }
    return gen_result(vm, arg_at(args, argc, 0), true);
}

private Value nat_gen_throw(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    if !value_is_generator(thisv) {
        vm_throw_error(vm, ERR_TYPE, "throw on a non-generator");
        return value_undefined();
    }
    JsGenerator* g = value_as_generator(thisv);
    if g.state == GEN_DONE || g.state == GEN_START {
        g.state = GEN_DONE;
        vm_throw(vm, arg_at(args, argc, 0));
        return value_undefined();
    }
    vm_push(vm, thisv);
    Value res = vm_gen_resume(vm, g, arg_at(args, argc, 0), true);
    if vm.has_pending {
        vm_pop(vm);
        return value_undefined();
    }
    vm_push(vm, res);
    Value r = gen_result(vm, res, g.state == GEN_DONE);
    vm.sp -= 2;
    return r;
}

private Value nat_gen_symiter(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    return thisv;
}

// --- Promise -----------------------------------------------------------------------------

private Value nat_resolve_fn(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    JsNative* me = value_as_native(callee);
    i32 rm = gc_root_mark(&vm.heap);
    Value a = arg_at(args, argc, 0);
    gc_root(&vm.heap, a);
    vm_promise_settle(vm, me.env0, a, false);
    gc_root_reset(&vm.heap, rm);
    return value_undefined();
}

private Value nat_reject_fn(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    JsNative* me = value_as_native(callee);
    i32 rm = gc_root_mark(&vm.heap);
    Value a = arg_at(args, argc, 0);
    gc_root(&vm.heap, a);
    vm_promise_settle(vm, me.env0, a, true);
    gc_root_reset(&vm.heap, rm);
    return value_undefined();
}

private Value nat_promise_ctor(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    Value executor = arg_at(args, argc, 0);
    if !value_is_callable(executor) {
        vm_throw_error(vm, ERR_TYPE, "Promise executor is not a function");
        return value_undefined();
    }
    Value p = vm_promise_new(vm);
    i32 rm = gc_root_mark(&vm.heap);
    gc_root(&vm.heap, p);
    JsNative* res = js_new_native(&vm.heap, &nat_resolve_fn, "resolve");
    res.env0 = p;
    gc_root(&vm.heap, value_cell(&res.head));
    JsNative* rej = js_new_native(&vm.heap, &nat_reject_fn, "reject");
    rej.env0 = p;
    gc_root(&vm.heap, value_cell(&rej.head));
    Value[2] ca = { value_cell(&res.head), value_cell(&rej.head) };
    ignore vm_call_value(vm, executor, value_undefined(), &ca[0], 2);
    if vm.has_pending {
        Value e = vm.pending;
        vm.has_pending = false;
        vm.pending = value_undefined();
        gc_root(&vm.heap, e);
        vm_promise_settle(vm, p, e, true);
    }
    gc_root_reset(&vm.heap, rm);
    return p;
}

private Value nat_promise_resolve(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    Value v = arg_at(args, argc, 0);
    if vm_is_promise(vm, v) { return v; }
    i32 rm = gc_root_mark(&vm.heap);
    gc_root(&vm.heap, v);
    Value p = vm_promise_new(vm);
    gc_root(&vm.heap, p);
    vm_promise_settle(vm, p, v, false);
    gc_root_reset(&vm.heap, rm);
    return p;
}

private Value nat_promise_reject(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    i32 rm = gc_root_mark(&vm.heap);
    Value v = arg_at(args, argc, 0);
    gc_root(&vm.heap, v);
    Value p = vm_promise_new(vm);
    gc_root(&vm.heap, p);
    vm_promise_settle(vm, p, v, true);
    gc_root_reset(&vm.heap, rm);
    return p;
}

private Value nat_promise_then(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    if !vm_is_promise(vm, thisv) {
        vm_throw_error(vm, ERR_TYPE, "then on a non-promise");
        return value_undefined();
    }
    return vm_promise_then(vm, thisv, arg_at(args, argc, 0), arg_at(args, argc, 1));
}

private Value nat_promise_catch(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    if !vm_is_promise(vm, thisv) {
        vm_throw_error(vm, ERR_TYPE, "catch on a non-promise");
        return value_undefined();
    }
    return vm_promise_then(vm, thisv, value_undefined(), arg_at(args, argc, 0));
}

// finally: run the callback on both paths, forwarding the settlement.
private Value nat_finally_pass(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    JsNative* me = value_as_native(callee);
    if value_is_callable(me.env0) {
        Value dummy = value_undefined();
        ignore vm_call_value(vm, me.env0, value_undefined(), &dummy, 0);
        if vm.has_pending { return value_undefined(); }
    }
    return arg_at(args, argc, 0);
}

private Value nat_promise_finally(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    if !vm_is_promise(vm, thisv) {
        vm_throw_error(vm, ERR_TYPE, "finally on a non-promise");
        return value_undefined();
    }
    Value cb = arg_at(args, argc, 0);
    i32 rm = gc_root_mark(&vm.heap);
    JsNative* onf = js_new_native(&vm.heap, &nat_finally_pass, "finally");
    onf.env0 = cb;
    gc_root(&vm.heap, value_cell(&onf.head));
    Value r = vm_promise_then(vm, thisv, value_cell(&onf.head), value_cell(&onf.head));
    gc_root_reset(&vm.heap, rm);
    return r;
}

// Promise.all: collects an array of results; rejects on the first
// rejection. Uses a shared state object counted down by element natives.
private Value nat_all_elem(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    JsNative* me = value_as_native(callee);
    JsObject* st = value_as_object(me.env0);   // { results, remaining, promise }
    i32 idx = value_as_int(me.env1);
    i32 rm = gc_root_mark(&vm.heap);
    Value resultsv;
    ignore js_get_prop(st, vm_atom(vm, "results"), &resultsv);
    js_array_set(value_as_object(resultsv), idx, arg_at(args, argc, 0));
    Value remv;
    ignore js_get_prop(st, vm_atom(vm, "remaining"), &remv);
    i32 rem = value_as_int(remv) - 1;
    js_set_prop(st, vm_atom(vm, "remaining"), value_int(rem));
    if rem == 0 {
        Value pv;
        ignore js_get_prop(st, vm_atom(vm, "promise"), &pv);
        gc_root(&vm.heap, pv);
        vm_promise_settle(vm, pv, resultsv, false);
    }
    gc_root_reset(&vm.heap, rm);
    return value_undefined();
}

private Value nat_all_rej(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    JsNative* me = value_as_native(callee);
    JsObject* st = value_as_object(me.env0);
    Value pv;
    ignore js_get_prop(st, vm_atom(vm, "promise"), &pv);
    i32 rm = gc_root_mark(&vm.heap);
    gc_root(&vm.heap, pv);
    Value a = arg_at(args, argc, 0);
    gc_root(&vm.heap, a);
    vm_promise_settle(vm, pv, a, true);
    gc_root_reset(&vm.heap, rm);
    return value_undefined();
}

private Value nat_promise_all(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    Value list = arg_at(args, argc, 0);
    if !value_is_array(list) {
        vm_throw_error(vm, ERR_TYPE, "Promise.all expects an array");
        return value_undefined();
    }
    JsObject* items = value_as_object(list);
    i32 n = items.elen;
    i32 rm = gc_root_mark(&vm.heap);
    Value p = vm_promise_new(vm);
    gc_root(&vm.heap, p);
    JsObject* st = js_new_object(&vm.heap, null);
    gc_root(&vm.heap, value_cell(&st.head));
    JsObject* results = js_new_array(&vm.heap, vm.array_proto);
    js_array_set_length(results, n);
    js_set_prop(st, vm_atom(vm, "results"), value_cell(&results.head));
    js_set_prop(st, vm_atom(vm, "remaining"), value_int(n));
    js_set_prop(st, vm_atom(vm, "promise"), p);
    if n == 0 {
        vm_promise_settle(vm, p, value_cell(&results.head), false);
        gc_root_reset(&vm.heap, rm);
        return p;
    }
    for i32 i = 0; i < n; i++ {
        Value ev = js_array_get(items, i);
        Value evp;
        if vm_is_promise(vm, ev) {
            evp = ev;
        } else {
            evp = vm_promise_new(vm);
            vm_push(vm, evp);
            vm_promise_settle(vm, evp, ev, false);
            vm_pop(vm);
        }
        vm_push(vm, evp);
        JsNative* onf = js_new_native(&vm.heap, &nat_all_elem, "all");
        onf.env0 = value_cell(&st.head);
        onf.env1 = value_int(i);
        vm_push(vm, value_cell(&onf.head));
        JsNative* onr = js_new_native(&vm.heap, &nat_all_rej, "all");
        onr.env0 = value_cell(&st.head);
        Value onfv = vm_pop_ret(vm, value_cell(&onf.head));
        ignore vm_promise_then(vm, evp, onfv, value_cell(&onr.head));
        vm_pop(vm);
    }
    gc_root_reset(&vm.heap, rm);
    return p;
}

private Value nat_race_settle(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    JsNative* me = value_as_native(callee);
    i32 rm = gc_root_mark(&vm.heap);
    Value a = arg_at(args, argc, 0);
    gc_root(&vm.heap, a);
    vm_promise_settle(vm, me.env0, a, me.env1.bits == value_bool(true).bits);
    gc_root_reset(&vm.heap, rm);
    return value_undefined();
}

private Value nat_promise_race(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    Value list = arg_at(args, argc, 0);
    if !value_is_array(list) {
        vm_throw_error(vm, ERR_TYPE, "Promise.race expects an array");
        return value_undefined();
    }
    JsObject* items = value_as_object(list);
    i32 rm = gc_root_mark(&vm.heap);
    Value p = vm_promise_new(vm);
    gc_root(&vm.heap, p);
    for i32 i = 0; i < items.elen; i++ {
        Value ev = js_array_get(items, i);
        Value evp;
        if vm_is_promise(vm, ev) {
            evp = ev;
        } else {
            evp = vm_promise_new(vm);
            vm_push(vm, evp);
            vm_promise_settle(vm, evp, ev, false);
            vm_pop(vm);
        }
        vm_push(vm, evp);
        JsNative* onf = js_new_native(&vm.heap, &nat_race_settle, "race");
        onf.env0 = p;
        onf.env1 = value_bool(false);
        vm_push(vm, value_cell(&onf.head));
        JsNative* onr = js_new_native(&vm.heap, &nat_race_settle, "race");
        onr.env0 = p;
        onr.env1 = value_bool(true);
        Value onfv = vm_pop_ret(vm, value_cell(&onf.head));
        ignore vm_promise_then(vm, evp, onfv, value_cell(&onr.head));
        vm_pop(vm);
    }
    gc_root_reset(&vm.heap, rm);
    return p;
}

// --- timers ------------------------------------------------------------------------------

private Value nat_set_timeout(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    Value cbfn = arg_at(args, argc, 0);
    if !value_is_callable(cbfn) { return value_int(0); }
    f64 delay = argc > 1 ? js_to_number(*(args + 1)) : 0.0;
    if delay != delay || delay < 0.0 { delay = 0.0; }
    return value_int(vm_add_timer(vm, cbfn, delay));
}

private Value nat_clear_timeout(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    vm_clear_timer(vm, to_int_arg(arg_at(args, argc, 0)));
    return value_undefined();
}

private Value nat_queue_microtask(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    Value cbfn = arg_at(args, argc, 0);
    if value_is_callable(cbfn) {
        // schedule via an already-resolved promise reaction
        i32 rm = gc_root_mark(&vm.heap);
        Value p = vm_promise_new(vm);
        gc_root(&vm.heap, p);
        vm_promise_settle(vm, p, value_undefined(), false);
        ignore vm_promise_then(vm, p, cbfn, value_undefined());
        gc_root_reset(&vm.heap, rm);
    }
    return value_undefined();
}

// --- Map and Set ------------------------------------------------------------------

// Finds the live slot index of key, or -1.
private i32 map_find(JsMap* mp, Value key) {
    for i32 i = 0; i < mp.len; i++ {
        if *(mp.live + i) && js_same_value_zero(*(mp.keys + i), key) { return i; }
    }
    return -1;
}

private void map_put(JsMap* mp, Value key, Value val) {
    i32 at = map_find(mp, key);
    if at >= 0 {
        *(mp.vals + at) = val;
        return;
    }
    map_reserve(mp);
    *(mp.keys + mp.len) = key;
    *(mp.vals + mp.len) = val;
    *(mp.live + mp.len) = true;
    mp.len++;
    mp.count++;
}

private JsMap* this_map(VM* vm, Value thisv) {
    if value_is_map(thisv) { return value_as_map(thisv); }
    vm_throw_error(vm, ERR_TYPE, "receiver is not a Map or Set");
    return null;
}

private Value make_map(VM* vm, Value iterable, bool is_set) {
    JsMap* mp = js_new_map(&vm.heap, is_set ? vm_set_proto(vm) : vm_map_proto(vm), is_set);
    if bi_nullish(iterable) { return value_cell(&mp.head); }
    i32 rm = gc_root_mark(&vm.heap);
    gc_root(&vm.heap, value_cell(&mp.head));
    if value_is_array(iterable) {
        JsObject* a = value_as_object(iterable);
        for i32 i = 0; i < a.elen; i++ {
            Value e = js_array_get(a, i);
            if is_set {
                map_put(mp, e, value_undefined());
            } else if value_is_array(e) {
                JsObject* pair = value_as_object(e);
                map_put(mp, js_array_get(pair, 0), js_array_get(pair, 1));
            }
        }
    } else {
        // general iterables: strings, other Sets/Maps, generators
        Value it;
        if vm_get_iterator(vm, iterable, &it) {
            gc_root(&vm.heap, it);
            while true {
                Value e;
                bool done;
                if !vm_iter_next(vm, it, &e, &done) { break; }
                if done { break; }
                gc_root(&vm.heap, e);
                if is_set {
                    map_put(mp, e, value_undefined());
                } else if value_is_array(e) {
                    JsObject* pair = value_as_object(e);
                    map_put(mp, js_array_get(pair, 0), js_array_get(pair, 1));
                }
            }
        }
        if vm.has_pending {
            gc_root_reset(&vm.heap, rm);
            return value_undefined();
        }
    }
    gc_root_reset(&vm.heap, rm);
    return value_cell(&mp.head);
}

private Value nat_map_ctor(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    return make_map(as_vm(vmp), arg_at(args, argc, 0), false);
}

private Value nat_set_ctor(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    return make_map(as_vm(vmp), arg_at(args, argc, 0), true);
}

private Value nat_map_set(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    JsMap* mp = this_map(vm, thisv);
    if mp == null { return value_undefined(); }
    map_put(mp, arg_at(args, argc, 0), arg_at(args, argc, 1));
    return thisv;
}

private Value nat_set_add(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    JsMap* mp = this_map(vm, thisv);
    if mp == null { return value_undefined(); }
    map_put(mp, arg_at(args, argc, 0), value_undefined());
    return thisv;
}

private Value nat_map_get(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    JsMap* mp = this_map(vm, thisv);
    if mp == null { return value_undefined(); }
    i32 at = map_find(mp, arg_at(args, argc, 0));
    if at < 0 { return value_undefined(); }
    return *(mp.vals + at);
}

private Value nat_map_has(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    JsMap* mp = this_map(vm, thisv);
    if mp == null { return value_undefined(); }
    return value_bool(map_find(mp, arg_at(args, argc, 0)) >= 0);
}

private Value nat_map_delete(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    JsMap* mp = this_map(vm, thisv);
    if mp == null { return value_undefined(); }
    i32 at = map_find(mp, arg_at(args, argc, 0));
    if at < 0 { return value_bool(false); }
    *(mp.live + at) = false;
    mp.count--;
    return value_bool(true);
}

private Value nat_map_clear(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    JsMap* mp = this_map(vm, thisv);
    if mp == null { return value_undefined(); }
    mp.len = 0;
    mp.count = 0;
    return value_undefined();
}

private Value nat_map_size(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    JsMap* mp = this_map(vm, thisv);
    if mp == null { return value_int(0); }
    return value_int(mp.count);
}

private Value nat_map_foreach(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    JsMap* mp = this_map(vm, thisv);
    if mp == null { return value_undefined(); }
    Value fun = arg_at(args, argc, 0);
    if !value_is_callable(fun) {
        vm_throw_error(vm, ERR_TYPE, "callback is not a function");
        return value_undefined();
    }
    i32 rm = gc_root_mark(&vm.heap);
    gc_root(&vm.heap, thisv);
    for i32 i = 0; i < mp.len; i++ {
        if !*(mp.live + i) { continue; }
        Value key = *(mp.keys + i);
        Value val = mp.is_set ? key : *(mp.vals + i);
        Value[3] ca = { val, key, thisv };
        ignore vm_call_value(vm, fun, value_undefined(), &ca[0], 3);
        if vm.has_pending { break; }
    }
    gc_root_reset(&vm.heap, rm);
    return value_undefined();
}

// Snapshot entries into an array (keys, values, or [k,v] pairs).
private Value map_collect(VM* vm, JsMap* mp, i32 mode) {
    JsObject* arr = js_new_array(&vm.heap, vm.array_proto);
    i32 rm = gc_root_mark(&vm.heap);
    gc_root(&vm.heap, value_cell(&arr.head));
    i32 n = 0;
    for i32 i = 0; i < mp.len; i++ {
        if !*(mp.live + i) { continue; }
        Value key = *(mp.keys + i);
        if mode == 0 {
            js_array_set(arr, n, key);
        } else if mode == 1 {
            js_array_set(arr, n, mp.is_set ? key : *(mp.vals + i));
        } else {
            JsObject* pair = js_new_array(&vm.heap, vm.array_proto);
            js_array_set(arr, n, value_cell(&pair.head));
            js_array_set(pair, 0, key);
            js_array_set(pair, 1, mp.is_set ? key : *(mp.vals + i));
        }
        n++;
    }
    gc_root_reset(&vm.heap, rm);
    return value_cell(&arr.head);
}

private Value nat_map_keys(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    JsMap* mp = this_map(vm, thisv);
    if mp == null { return value_undefined(); }
    return make_index_iterator(vm, map_collect(vm, mp, 0), 0);
}

private Value nat_map_values(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    JsMap* mp = this_map(vm, thisv);
    if mp == null { return value_undefined(); }
    return make_index_iterator(vm, map_collect(vm, mp, 1), 0);
}

private Value nat_map_entries(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    JsMap* mp = this_map(vm, thisv);
    if mp == null { return value_undefined(); }
    return make_index_iterator(vm, map_collect(vm, mp, 2), 0);
}

// --- Date -------------------------------------------------------------------------------

private f64 date_ms(VM* vm, Value thisv) {
    if !value_is_object(thisv) { return 0.0 / 0.0; }
    Value t;
    if js_get_prop(value_as_object(thisv), bi_atom(vm, "%t"), &t) {
        return js_to_number(t);
    }
    return 0.0 / 0.0;
}

private bool is_leap(i64 y) {
    return (y % 4 == 0 && y % 100 != 0) || y % 400 == 0;
}

private i32 days_in_month(i64 y, i32 m) {
    i32[12] dm = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    if m == 1 && is_leap(y) { return 29; }
    return dm[m];
}

struct DateParts {
    i64 year;
    i32 month;
    i32 day;
    i32 hour;
    i32 min;
    i32 sec;
    i32 ms;
    i32 wday;
}

// Decomposes a UTC millisecond timestamp.
private DateParts date_decompose(f64 t) {
    DateParts d;
    i64 ms_total = cast(i64, t);
    i64 days = ms_total / 86400000;
    i64 rem = ms_total % 86400000;
    if rem < 0 { rem += 86400000; days--; }
    d.ms = cast(i32, rem % 1000);
    rem = rem / 1000;
    d.sec = cast(i32, rem % 60);
    rem = rem / 60;
    d.min = cast(i32, rem % 60);
    d.hour = cast(i32, rem / 60);
    d.wday = cast(i32, ((days % 7) + 11) % 7);   // 1970-01-01 was Thursday(4)
    i64 y = 1970;
    while true {
        i64 dy = is_leap(y) ? 366 : 365;
        if days >= dy { days -= dy; y++; }
        else if days < 0 { y--; days += is_leap(y) ? 366 : 365; }
        else { break; }
    }
    d.year = y;
    i32 mo = 0;
    while true {
        i32 dim = days_in_month(y, mo);
        if days >= dim { days -= dim; mo++; }
        else { break; }
    }
    d.month = mo;
    d.day = cast(i32, days) + 1;
    return d;
}

private f64 date_compose(i64 y, i32 mo, i32 day, i32 hr, i32 mi, i32 se, i32 mms) {
    while mo < 0 { mo += 12; y--; }
    while mo >= 12 { mo -= 12; y++; }
    i64 days = 0;
    if y >= 1970 {
        for i64 yy = 1970; yy < y; yy++ { days += is_leap(yy) ? 366 : 365; }
    } else {
        for i64 yy = y; yy < 1970; yy++ { days -= is_leap(yy) ? 366 : 365; }
    }
    for i32 m = 0; m < mo; m++ { days += days_in_month(y, m); }
    days += day - 1;
    return cast(f64, days) * 86400000.0 + cast(f64, hr) * 3600000.0
        + cast(f64, mi) * 60000.0 + cast(f64, se) * 1000.0 + cast(f64, mms);
}

// years 0..99 map to 1900..1999 (legacy Date behavior)
private i64 date_year_expand(i64 y) {
    if y >= 0 && y <= 99 { return y + 1900; }
    return y;
}

private Value nat_date_ctor(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    JsObject* d;
    if value_is_object(thisv) { d = value_as_object(thisv); }
    else { d = js_new_object(&vm.heap, vm_date_proto(vm)); }
    i32 rm = gc_root_mark(&vm.heap);
    gc_root(&vm.heap, value_cell(&d.head));
    f64 t;
    if argc == 0 {
        t = vm_now_millis(vm);
    } else if argc == 1 {
        t = js_to_number(*(args));
    } else {
        i64 y = date_year_expand(cast(i64, js_to_number(*(args))));
        i32 mo = to_int_arg(arg_at(args, argc, 1));
        i32 day = argc > 2 ? to_int_arg(*(args + 2)) : 1;
        i32 hr = argc > 3 ? to_int_arg(*(args + 3)) : 0;
        i32 mi = argc > 4 ? to_int_arg(*(args + 4)) : 0;
        i32 se = argc > 5 ? to_int_arg(*(args + 5)) : 0;
        i32 mms = argc > 6 ? to_int_arg(*(args + 6)) : 0;
        t = date_compose(y, mo, day, hr, mi, se, mms);
    }
    js_set_prop(d, bi_atom(vm, "%t"), value_number(t));
    gc_root_reset(&vm.heap, rm);
    return value_cell(&d.head);
}

private Value nat_date_now(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    return js_number_value(vm_now_millis(vm));
}

// Date.UTC(year, month=0, day=1, h=0, m=0, s=0, ms=0) -> timestamp.
private Value nat_date_utc(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    if argc == 0 { return value_number(0.0 / 0.0); }
    i64 y = date_year_expand(cast(i64, js_to_number(*(args))));
    i32 mo = argc > 1 ? to_int_arg(*(args + 1)) : 0;
    i32 day = argc > 2 ? to_int_arg(*(args + 2)) : 1;
    i32 hr = argc > 3 ? to_int_arg(*(args + 3)) : 0;
    i32 mi = argc > 4 ? to_int_arg(*(args + 4)) : 0;
    i32 se = argc > 5 ? to_int_arg(*(args + 5)) : 0;
    i32 mms = argc > 6 ? to_int_arg(*(args + 6)) : 0;
    return js_number_value(date_compose(y, mo, day, hr, mi, se, mms));
}

private Value nat_date_gettime(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    return js_number_value(date_ms(vm, thisv));
}

private Value nat_date_getfullyear(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    return js_number_value(cast(f64, date_decompose(date_ms(vm, thisv)).year));
}
private Value nat_date_getmonth(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    return value_int(date_decompose(date_ms(as_vm(vmp), thisv)).month);
}
private Value nat_date_getdate(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    return value_int(date_decompose(date_ms(as_vm(vmp), thisv)).day);
}
private Value nat_date_getday(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    return value_int(date_decompose(date_ms(as_vm(vmp), thisv)).wday);
}
private Value nat_date_gethours(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    return value_int(date_decompose(date_ms(as_vm(vmp), thisv)).hour);
}
private Value nat_date_getminutes(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    return value_int(date_decompose(date_ms(as_vm(vmp), thisv)).min);
}
private Value nat_date_getseconds(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    return value_int(date_decompose(date_ms(as_vm(vmp), thisv)).sec);
}
private Value nat_date_getms(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    return value_int(date_decompose(date_ms(as_vm(vmp), thisv)).ms);
}

private void pad2(str_buf* sb, i32 v) {
    if v < 10 { str_buf_add(sb, "0"); }
    string s = format("{}", v);
    str_buf_add(sb, s);
    free(s);
}

private Value nat_date_toiso(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    DateParts d = date_decompose(date_ms(vm, thisv));
    str_buf sb;
    str_buf_init(&sb);
    string y = format("{}", d.year);
    if d.year < 1000 { str_buf_add(&sb, "0"); }
    if d.year < 100 { str_buf_add(&sb, "0"); }
    if d.year < 10 { str_buf_add(&sb, "0"); }
    str_buf_add(&sb, y);
    free(y);
    str_buf_add(&sb, "-");
    pad2(&sb, d.month + 1);
    str_buf_add(&sb, "-");
    pad2(&sb, d.day);
    str_buf_add(&sb, "T");
    pad2(&sb, d.hour);
    str_buf_add(&sb, ":");
    pad2(&sb, d.min);
    str_buf_add(&sb, ":");
    pad2(&sb, d.sec);
    str_buf_add(&sb, ".");
    if d.ms < 100 { str_buf_add(&sb, "0"); }
    if d.ms < 10 { str_buf_add(&sb, "0"); }
    string mss = format("{}", d.ms);
    str_buf_add(&sb, mss);
    free(mss);
    str_buf_add(&sb, "Z");
    Value r = new_str(vm, str_buf_to_str(&sb));
    str_buf_free(&sb);
    return r;
}

// --- RegExp -----------------------------------------------------------------------------

private Value nat_regexp_ctor(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    Value pat = arg_at(args, argc, 0);
    if vm_is_regexp(vm, pat) && argc < 2 { return pat; }
    i32 rm = gc_root_mark(&vm.heap);
    Value src;
    if vm_is_regexp(vm, pat) {
        ignore js_get_prop(value_as_object(pat), vm_atom(vm, "source"), &src);
    } else if value_is_undefined(pat) {
        src = new_str(vm, "");
    } else {
        src = js_to_string_value(vm, pat);
    }
    gc_root(&vm.heap, src);
    Value flagsv = arg_at(args, argc, 1);
    str flags = "";
    if !value_is_undefined(flagsv) {
        Value fv = js_to_string_value(vm, flagsv);
        gc_root(&vm.heap, fv);
        flags = sview(fv);
    }
    Value re = vm_new_regexp(vm, sview(src), flags);
    gc_root_reset(&vm.heap, rm);
    return re;
}

// Runs the compiled prog; on match builds a result array with index +
// input, advances lastIndex for global/sticky. Returns null value on
// no match. `re` and `subject` stay rooted by the caller.
private Value regexp_exec_impl(VM* vm, Value re, Value subjectv) {
    RegexProg* prog = vm_regexp_prog(vm, re);
    if prog == null { return value_null(); }
    str s = sview(subjectv);
    i32 start = 0;
    Value liv;
    if js_get_prop(value_as_object(re), vm_atom_lastindex(vm), &liv) {
        if regex_is_global(prog) || regex_is_sticky(prog) { start = to_int_arg(liv); }
    }
    if start < 0 { start = 0; }
    i32 ncap = 2 * (regex_ngroups(prog) + 1);
    i32* caps = alloc<i32>(ncap);
    bool ok = regex_exec(prog, s, start, caps);
    if !ok {
        free(caps);
        if regex_is_global(prog) || regex_is_sticky(prog) {
            js_set_prop(value_as_object(re), vm_atom_lastindex(vm), value_int(0));
        }
        return value_null();
    }
    JsObject* arr = js_new_array(&vm.heap, vm.array_proto);
    i32 rm = gc_root_mark(&vm.heap);
    gc_root(&vm.heap, value_cell(&arr.head));
    i32 ng = regex_ngroups(prog);
    for i32 g = 0; g <= ng; g++ {
        i32 gs = *(caps + 2 * g);
        i32 ge = *(caps + 2 * g + 1);
        if gs < 0 {
            js_array_set(arr, g, value_undefined());
        } else {
            str sub;
            sub.data = s.data + gs;
            sub.len = ge - gs;
            js_array_set(arr, g, new_str(vm, sub));
        }
    }
    js_set_prop(arr, vm_atom_index(vm), value_int(*(caps + 0)));
    js_set_prop(arr, bi_atom(vm, "input"), subjectv);
    // result.groups: undefined unless the pattern has named groups
    if regex_has_named(prog) {
        JsObject* groups = js_new_object(&vm.heap, null);
        js_set_prop(arr, bi_atom(vm, "groups"), value_cell(&groups.head));
        for i32 g = 1; g <= ng; g++ {
            str nm = regex_group_name(prog, g);
            if nm.len > 0 {
                i32 gs = *(caps + 2 * g);
                i32 ge = *(caps + 2 * g + 1);
                Value v = value_undefined();
                if gs >= 0 {
                    str sub;
                    sub.data = s.data + gs;
                    sub.len = ge - gs;
                    v = new_str(vm, sub);
                }
                js_set_prop(groups, bi_atom(vm, nm), v);
            }
        }
    } else {
        js_set_prop(arr, bi_atom(vm, "groups"), value_undefined());
    }
    if regex_is_global(prog) || regex_is_sticky(prog) {
        js_set_prop(value_as_object(re), vm_atom_lastindex(vm), value_int(*(caps + 1)));
    }
    free(caps);
    gc_root_reset(&vm.heap, rm);
    return value_cell(&arr.head);
}

private Value nat_regexp_exec(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    if !vm_is_regexp(vm, thisv) {
        vm_throw_error(vm, ERR_TYPE, "exec on a non-regexp");
        return value_undefined();
    }
    i32 rm = gc_root_mark(&vm.heap);
    gc_root(&vm.heap, thisv);
    Value sv2 = js_to_string_value(vm, arg_at(args, argc, 0));
    gc_root(&vm.heap, sv2);
    Value r = regexp_exec_impl(vm, thisv, sv2);
    gc_root_reset(&vm.heap, rm);
    return r;
}

private Value nat_regexp_test(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    if !vm_is_regexp(vm, thisv) {
        vm_throw_error(vm, ERR_TYPE, "test on a non-regexp");
        return value_undefined();
    }
    i32 rm = gc_root_mark(&vm.heap);
    gc_root(&vm.heap, thisv);
    Value sv2 = js_to_string_value(vm, arg_at(args, argc, 0));
    gc_root(&vm.heap, sv2);
    Value r = regexp_exec_impl(vm, thisv, sv2);
    gc_root_reset(&vm.heap, rm);
    return value_bool(!value_is_null(r));
}

private Value nat_regexp_tostring(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    i32 rm = gc_root_mark(&vm.heap);
    Value src;
    Value flg;
    ignore js_get_prop(value_as_object(thisv), vm_atom(vm, "source"), &src);
    ignore js_get_prop(value_as_object(thisv), vm_atom(vm, "flags"), &flg);
    str_buf sb;
    str_buf_init(&sb);
    str_buf_add(&sb, "/");
    if value_is_string(src) { str_buf_add(&sb, sview(src)); }
    str_buf_add(&sb, "/");
    if value_is_string(flg) { str_buf_add(&sb, sview(flg)); }
    Value r = new_str(vm, str_buf_to_str(&sb));
    str_buf_free(&sb);
    gc_root_reset(&vm.heap, rm);
    return r;
}

// String.prototype.match / matchAll / search / split(regex) /
// replace(regex): coerce a RegExp argument and drive exec.

private Value str_regexp_arg(VM* vm, Value v) {
    if vm_is_regexp(vm, v) { return v; }
    i32 rm = gc_root_mark(&vm.heap);
    Value sv2 = js_to_string_value(vm, v);
    gc_root(&vm.heap, sv2);
    Value re = vm_new_regexp(vm, sview(sv2), "");
    gc_root_reset(&vm.heap, rm);
    return re;
}

private Value nat_str_match(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    i32 rm = gc_root_mark(&vm.heap);
    Value sv2 = js_to_string_value(vm, thisv);
    gc_root(&vm.heap, sv2);
    Value re = str_regexp_arg(vm, arg_at(args, argc, 0));
    if vm.has_pending { gc_root_reset(&vm.heap, rm); return value_undefined(); }
    gc_root(&vm.heap, re);
    RegexProg* prog = vm_regexp_prog(vm, re);
    if prog != null && regex_is_global(prog) {
        // return an array of all whole matches
        JsObject* out = js_new_array(&vm.heap, vm.array_proto);
        gc_root(&vm.heap, value_cell(&out.head));
        js_set_prop(value_as_object(re), vm_atom_lastindex(vm), value_int(0));
        i32 n = 0;
        i32 guard = 0;
        while guard < 1000000 {
            guard++;
            Value mv = regexp_exec_impl(vm, re, sv2);
            if value_is_null(mv) { break; }
            gc_root(&vm.heap, mv);
            Value whole = js_array_get(value_as_object(mv), 0);
            js_array_set(out, n, whole);
            n++;
            // advance past a zero-width match so lastIndex progresses
            if value_is_string(whole) && value_as_string(whole).len == 0 {
                Value liv;
                ignore js_get_prop(value_as_object(re), vm_atom_lastindex(vm), &liv);
                js_set_prop(value_as_object(re), vm_atom_lastindex(vm),
                    value_int(to_int_arg(liv) + 1));
            }
        }
        gc_root_reset(&vm.heap, rm);
        if n == 0 { return value_null(); }
        return value_cell(&out.head);
    }
    Value r = regexp_exec_impl(vm, re, sv2);
    gc_root_reset(&vm.heap, rm);
    return r;
}

private Value nat_str_matchall(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    i32 rm = gc_root_mark(&vm.heap);
    Value sv2 = js_to_string_value(vm, thisv);
    gc_root(&vm.heap, sv2);
    Value re = str_regexp_arg(vm, arg_at(args, argc, 0));
    if vm.has_pending { gc_root_reset(&vm.heap, rm); return value_undefined(); }
    gc_root(&vm.heap, re);
    JsObject* out = js_new_array(&vm.heap, vm.array_proto);
    gc_root(&vm.heap, value_cell(&out.head));
    js_set_prop(value_as_object(re), vm_atom_lastindex(vm), value_int(0));
    RegexProg* prog = vm_regexp_prog(vm, re);
    bool global = prog != null && regex_is_global(prog);
    i32 n = 0;
    i32 guard = 0;
    while guard < 1000000 {
        guard++;
        Value m = regexp_exec_impl(vm, re, sv2);
        if value_is_null(m) { break; }
        gc_root(&vm.heap, m);
        js_array_set(out, n, m);
        n++;
        if !global { break; }
        Value whole = js_array_get(value_as_object(m), 0);
        if value_is_string(whole) && value_as_string(whole).len == 0 {
            Value liv;
            ignore js_get_prop(value_as_object(re), vm_atom_lastindex(vm), &liv);
            js_set_prop(value_as_object(re), vm_atom_lastindex(vm), value_int(to_int_arg(liv) + 1));
        }
    }
    Value it = make_index_iterator(vm, value_cell(&out.head), 0);
    gc_root_reset(&vm.heap, rm);
    return it;
}

private Value nat_str_search(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    i32 rm = gc_root_mark(&vm.heap);
    Value sv2 = js_to_string_value(vm, thisv);
    gc_root(&vm.heap, sv2);
    Value re = str_regexp_arg(vm, arg_at(args, argc, 0));
    if vm.has_pending { gc_root_reset(&vm.heap, rm); return value_undefined(); }
    gc_root(&vm.heap, re);
    RegexProg* prog = vm_regexp_prog(vm, re);
    i32 result = -1;
    if prog != null {
        i32 ncap = 2 * (regex_ngroups(prog) + 1);
        i32* caps = alloc<i32>(ncap);
        if regex_exec(prog, sview(sv2), 0, caps) { result = *(caps + 0); }
        free(caps);
    }
    gc_root_reset(&vm.heap, rm);
    return value_int(result);
}

// Substitutes $1..$99, $&, $$, and $<name> in a replacement template.
private void append_replacement(VM* vm, str_buf* sb, str tmpl, str subject, i32* caps, i32 ng, RegexProg* prog) {
    i32 i = 0;
    while i < tmpl.len {
        u8 c = *(tmpl.data + i);
        if c == '$' && i + 1 < tmpl.len {
            u8 n = *(tmpl.data + i + 1);
            if n == '$' { str_buf_add(sb, "$"); i += 2; continue; }
            if n == '<' && prog != null && regex_has_named(prog) {
                // $<name>
                i32 j = i + 2;
                while j < tmpl.len && *(tmpl.data + j) != '>' { j++; }
                if j < tmpl.len {
                    str name;
                    name.data = tmpl.data + i + 2;
                    name.len = j - (i + 2);
                    i32 g = regex_group_index(prog, name);
                    if g >= 1 {
                        i32 gs = *(caps + 2 * g);
                        i32 ge = *(caps + 2 * g + 1);
                        if gs >= 0 {
                            str sub;
                            sub.data = subject.data + gs;
                            sub.len = ge - gs;
                            str_buf_add(sb, sub);
                        }
                    }
                    i = j + 1;
                    continue;
                }
            }
            if n == '&' {
                str m;
                m.data = subject.data + *(caps + 0);
                m.len = *(caps + 1) - *(caps + 0);
                str_buf_add(sb, m);
                i += 2;
                continue;
            }
            if n >= '0' && n <= '9' {
                i32 nd = n;
                i32 g = nd - '0';
                i32 adv = 2;
                if i + 2 < tmpl.len {
                    u8 n2 = *(tmpl.data + i + 2);
                    if n2 >= '0' && n2 <= '9' {
                        i32 n2d = n2;
                        i32 g2 = g * 10 + (n2d - '0');
                        if g2 <= ng { g = g2; adv = 3; }
                    }
                }
                if g >= 1 && g <= ng {
                    i32 gs = *(caps + 2 * g);
                    i32 ge = *(caps + 2 * g + 1);
                    if gs >= 0 {
                        str sub;
                        sub.data = subject.data + gs;
                        sub.len = ge - gs;
                        str_buf_add(sb, sub);
                    }
                    i += adv;
                    continue;
                }
            }
        }
        str one;
        one.data = tmpl.data + i;
        one.len = 1;
        str_buf_add(sb, one);
        i++;
    }
}

private Value regexp_replace(VM* vm, Value sv2, Value re, Value repl) {
    RegexProg* prog = vm_regexp_prog(vm, re);
    if prog == null { return sv2; }
    str s = sview(sv2);
    bool global = regex_is_global(prog);
    bool fn_repl = value_is_callable(repl);
    i32 ng = regex_ngroups(prog);
    i32 ncap = 2 * (ng + 1);
    i32* caps = alloc<i32>(ncap);
    str_buf sb;
    str_buf_init(&sb);
    i32 rm = gc_root_mark(&vm.heap);
    i32 pos = 0;
    Value rtmpl = value_undefined();
    if !fn_repl {
        rtmpl = js_to_string_value(vm, repl);
        gc_root(&vm.heap, rtmpl);
    }
    while pos <= s.len {
        if !regex_exec(prog, s, pos, caps) { break; }
        i32 ms = *(caps + 0);
        i32 me = *(caps + 1);
        str pre;
        pre.data = s.data + pos;
        pre.len = ms - pos;
        str_buf_add(&sb, pre);
        if fn_repl {
            // (match, ...groups, offset, string [, namedGroups])
            bool named = regex_has_named(prog);
            i32 nargs = ng + 3 + (named ? 1 : 0);
            Value* ca = alloc<Value>(nargs);
            for i32 g = 0; g <= ng; g++ {
                i32 gs = *(caps + 2 * g);
                i32 ge = *(caps + 2 * g + 1);
                if gs < 0 {
                    *(ca + g) = value_undefined();
                } else {
                    str sub;
                    sub.data = s.data + gs;
                    sub.len = ge - gs;
                    *(ca + g) = new_str(vm, sub);
                }
            }
            *(ca + ng + 1) = value_int(ms);
            *(ca + ng + 2) = sv2;
            if named {
                JsObject* groups = js_new_object(&vm.heap, null);
                Value gv = value_cell(&groups.head);
                gc_root(&vm.heap, gv);
                for i32 g = 1; g <= ng; g++ {
                    str nm = regex_group_name(prog, g);
                    if nm.len > 0 {
                        i32 gs = *(caps + 2 * g);
                        Value gval = value_undefined();
                        if gs >= 0 {
                            str sub;
                            sub.data = s.data + gs;
                            sub.len = *(caps + 2 * g + 1) - gs;
                            gval = new_str(vm, sub);
                        }
                        js_set_prop(groups, bi_atom(vm, nm), gval);
                    }
                }
                *(ca + ng + 3) = gv;
            }
            Value fr = vm_call_value(vm, repl, value_undefined(), ca, nargs);
            free(ca);
            if vm.has_pending { break; }
            gc_root(&vm.heap, fr);
            Value frs = js_to_string_value(vm, fr);
            gc_root(&vm.heap, frs);
            str_buf_add(&sb, sview(frs));
        } else {
            append_replacement(vm, &sb, sview(rtmpl), s, caps, ng, prog);
        }
        if me > pos {
            pos = me;
        } else {
            // zero-width match: emit one char and advance
            if pos < s.len {
                str one;
                one.data = s.data + pos;
                one.len = 1;
                str_buf_add(&sb, one);
            }
            pos++;
        }
        if !global { break; }
    }
    str tail;
    tail.data = s.data + pos;
    tail.len = s.len - pos;
    if pos <= s.len { str_buf_add(&sb, tail); }
    Value r = new_str(vm, str_buf_to_str(&sb));
    str_buf_free(&sb);
    free(caps);
    gc_root_reset(&vm.heap, rm);
    return r;
}

// Extends String.prototype.replace to accept a RegExp first argument.
private Value nat_str_replace_x(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    Value pat = arg_at(args, argc, 0);
    if vm_is_regexp(vm, pat) {
        i32 rm = gc_root_mark(&vm.heap);
        Value sv2 = js_to_string_value(vm, thisv);
        gc_root(&vm.heap, sv2);
        Value r = regexp_replace(vm, sv2, pat, arg_at(args, argc, 1));
        gc_root_reset(&vm.heap, rm);
        return r;
    }
    return str_replace_impl(vm, thisv, args, argc, false);
}

private Value nat_str_split_x(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    Value sep = arg_at(args, argc, 0);
    if !vm_is_regexp(vm, sep) {
        return nat_str_split(vmp, callee, thisv, args, argc);
    }
    i32 rm = gc_root_mark(&vm.heap);
    Value sv2 = js_to_string_value(vm, thisv);
    gc_root(&vm.heap, sv2);
    str s = sview(sv2);
    RegexProg* prog = vm_regexp_prog(vm, sep);
    JsObject* out = js_new_array(&vm.heap, vm.array_proto);
    gc_root(&vm.heap, value_cell(&out.head));
    i32 ncap = 2 * (regex_ngroups(prog) + 1);
    i32* caps = alloc<i32>(ncap);
    i32 last = 0;
    i32 pos = 0;
    i32 n = 0;
    while pos <= s.len {
        if !regex_exec(prog, s, pos, caps) { break; }
        i32 ms = *(caps + 0);
        i32 me = *(caps + 1);
        if me == last && ms == last {
            pos++;
            continue;
        }
        str part;
        part.data = s.data + last;
        part.len = ms - last;
        js_array_set(out, n, new_str(vm, part));
        n++;
        last = me;
        pos = me > pos ? me : pos + 1;
    }
    str tail;
    tail.data = s.data + last;
    tail.len = s.len - last;
    js_array_set(out, n, new_str(vm, tail));
    free(caps);
    gc_root_reset(&vm.heap, rm);
    return value_cell(&out.head);
}

// --- install -------------------------------------------------------------------------------------

// Built-in methods/statics/accessors are non-enumerable but writable
// and configurable, matching how JS specifies them.
const u8 METHOD_ATTRS = PROP_WRITABLE | PROP_CONFIGURABLE;

private void def_method(VM* vm, JsObject* obj, str name, NativeFn f) {
    JsNative* n = js_new_native(&vm.heap, f, name);
    props_set_desc(&obj.props, bi_atom(vm, name), value_cell(&n.head), METHOD_ATTRS);
}

private JsNative* def_global_fn(VM* vm, str name, NativeFn f) {
    JsNative* n = js_new_native(&vm.heap, f, name);
    vm_set_global(vm, name, value_cell(&n.head));
    return n;
}

private void def_static(VM* vm, JsNative* ctor, str name, NativeFn f) {
    JsNative* m = js_new_native(&vm.heap, f, name);
    props_set_desc(&ctor.props, bi_atom(vm, name), value_cell(&m.head), METHOD_ATTRS);
}

// Constants (e.g. Math.PI): non-writable, non-enumerable, non-configurable.
private void def_value(VM* vm, JsObject* obj, str name, Value v) {
    props_set_desc(&obj.props, bi_atom(vm, name), v, 0);
}

// Links a prototype back to its constructor (proto.constructor = ctor).
private void link_ctor(VM* vm, JsObject* proto, JsNative* ctor) {
    props_set_desc(&proto.props, bi_atom(vm, "constructor"), value_cell(&ctor.head), METHOD_ATTRS);
}

// Installs a getter-only accessor property (non-enumerable, configurable).
private void def_accessor(VM* vm, JsObject* obj, str name, NativeFn getter) {
    JsNative* g = js_new_native(&vm.heap, getter, name);
    JsAccessor* ac = js_new_accessor(&vm.heap);
    ac.get = value_cell(&g.head);
    props_set_desc(&obj.props, bi_atom(vm, name), value_cell(&ac.head), PROP_CONFIGURABLE);
}

void builtins_install(VM* vm) {
    // prototypes first; VM fields make them GC roots immediately
    vm.object_proto = js_new_object(&vm.heap, null);
    vm.array_proto = js_new_object(&vm.heap, vm.object_proto);
    vm.string_proto = js_new_object(&vm.heap, vm.object_proto);
    vm.number_proto = js_new_object(&vm.heap, vm.object_proto);
    vm.boolean_proto = js_new_object(&vm.heap, vm.object_proto);
    vm.function_proto = js_new_object(&vm.heap, vm.object_proto);
    vm.error_protos[ERR_ERROR] = js_new_object(&vm.heap, vm.object_proto);
    for i32 i = 1; i < 5; i++ {
        vm.error_protos[i] = js_new_object(&vm.heap, vm.error_protos[ERR_ERROR]);
    }

    // Object
    JsNative* object_ctor = def_global_fn(vm, "Object", &nat_object_ctor);
    props_set(&object_ctor.props, vm.atom_prototype, value_cell(&vm.object_proto.head));
    def_static(vm, object_ctor, "keys", &nat_object_keys);
    def_static(vm, object_ctor, "values", &nat_object_values);
    def_static(vm, object_ctor, "entries", &nat_object_entries);
    def_static(vm, object_ctor, "assign", &nat_object_assign);
    def_static(vm, object_ctor, "create", &nat_object_create);
    def_static(vm, object_ctor, "getPrototypeOf", &nat_object_getproto);
    def_static(vm, object_ctor, "setPrototypeOf", &nat_object_setproto);
    def_static(vm, object_ctor, "getOwnPropertyNames", &nat_object_getownnames);
    def_static(vm, object_ctor, "fromEntries", &nat_object_fromentries);
    def_static(vm, object_ctor, "defineProperty", &nat_object_defineproperty);
    def_static(vm, object_ctor, "defineProperties", &nat_object_defineproperties);
    def_static(vm, object_ctor, "getOwnPropertyDescriptor", &nat_object_getownpropdesc);
    def_static(vm, object_ctor, "is", &nat_object_is);
    def_static(vm, object_ctor, "hasOwn", &nat_object_hasown);
    def_static(vm, object_ctor, "freeze", &nat_object_freeze);
    def_static(vm, object_ctor, "isFrozen", &nat_object_isfrozen);
    def_static(vm, object_ctor, "seal", &nat_object_seal);
    def_static(vm, object_ctor, "isSealed", &nat_object_issealed);
    def_static(vm, object_ctor, "preventExtensions", &nat_object_preventext);
    def_static(vm, object_ctor, "isExtensible", &nat_object_isextensible);
    def_method(vm, vm.object_proto, "hasOwnProperty", &nat_has_own);
    def_method(vm, vm.object_proto, "toString", &nat_object_tostring);

    // Array
    JsNative* array_ctor = def_global_fn(vm, "Array", &nat_array_ctor);
    props_set(&array_ctor.props, vm.atom_prototype, value_cell(&vm.array_proto.head));
    def_static(vm, array_ctor, "isArray", &nat_array_isarray);
    def_static(vm, array_ctor, "of", &nat_array_of);
    def_static(vm, array_ctor, "from", &nat_array_from);
    def_method(vm, vm.array_proto, "push", &nat_arr_push);
    def_method(vm, vm.array_proto, "pop", &nat_arr_pop);
    def_method(vm, vm.array_proto, "shift", &nat_arr_shift);
    def_method(vm, vm.array_proto, "unshift", &nat_arr_unshift);
    def_method(vm, vm.array_proto, "slice", &nat_arr_slice);
    def_method(vm, vm.array_proto, "splice", &nat_arr_splice);
    def_method(vm, vm.array_proto, "concat", &nat_arr_concat);
    def_method(vm, vm.array_proto, "join", &nat_arr_join);
    def_method(vm, vm.array_proto, "indexOf", &nat_arr_indexof);
    def_method(vm, vm.array_proto, "includes", &nat_arr_includes);
    def_method(vm, vm.array_proto, "map", &nat_arr_map);
    def_method(vm, vm.array_proto, "filter", &nat_arr_filter);
    def_method(vm, vm.array_proto, "forEach", &nat_arr_foreach);
    def_method(vm, vm.array_proto, "reduce", &nat_arr_reduce);
    def_method(vm, vm.array_proto, "reduceRight", &nat_arr_reduceright);
    def_method(vm, vm.array_proto, "some", &nat_arr_some);
    def_method(vm, vm.array_proto, "every", &nat_arr_every);
    def_method(vm, vm.array_proto, "find", &nat_arr_find);
    def_method(vm, vm.array_proto, "findIndex", &nat_arr_findindex);
    def_method(vm, vm.array_proto, "findLast", &nat_arr_findlast);
    def_method(vm, vm.array_proto, "at", &nat_arr_at);
    def_method(vm, vm.array_proto, "flat", &nat_arr_flat);
    def_method(vm, vm.array_proto, "flatMap", &nat_arr_flatmap);
    def_method(vm, vm.array_proto, "reverse", &nat_arr_reverse);
    def_method(vm, vm.array_proto, "sort", &nat_arr_sort);
    def_method(vm, vm.array_proto, "fill", &nat_arr_fill);
    def_method(vm, vm.array_proto, "toString", &nat_arr_join);
    def_method(vm, vm.array_proto, "copyWithin", &nat_arr_copywithin);
    def_method(vm, vm.array_proto, "lastIndexOf", &nat_arr_lastindexof);
    def_method(vm, vm.array_proto, "toSorted", &nat_arr_tosorted);
    def_method(vm, vm.array_proto, "toReversed", &nat_arr_toreversed);
    def_method(vm, vm.array_proto, "with", &nat_arr_with);
    def_method(vm, vm.array_proto, "values", &nat_arr_values);
    def_method(vm, vm.array_proto, "keys", &nat_arr_keys);
    def_method(vm, vm.array_proto, "entries", &nat_arr_entries);

    // String
    JsNative* string_ctor = def_global_fn(vm, "String", &nat_string_ctor);
    props_set(&string_ctor.props, vm.atom_prototype, value_cell(&vm.string_proto.head));
    def_static(vm, string_ctor, "fromCharCode", &nat_string_fromcharcode);
    def_static(vm, string_ctor, "fromCodePoint", &nat_string_fromcodepoint);
    def_static(vm, string_ctor, "raw", &nat_string_raw);
    def_method(vm, vm.string_proto, "charAt", &nat_str_charat);
    def_method(vm, vm.string_proto, "charCodeAt", &nat_str_charcodeat);
    def_method(vm, vm.string_proto, "codePointAt", &nat_str_codepointat);
    def_method(vm, vm.string_proto, "indexOf", &nat_str_indexof);
    def_method(vm, vm.string_proto, "lastIndexOf", &nat_str_lastindexof);
    def_method(vm, vm.string_proto, "includes", &nat_str_includes);
    def_method(vm, vm.string_proto, "startsWith", &nat_str_startswith);
    def_method(vm, vm.string_proto, "endsWith", &nat_str_endswith);
    def_method(vm, vm.string_proto, "slice", &nat_str_slice);
    def_method(vm, vm.string_proto, "substring", &nat_str_substring);
    def_method(vm, vm.string_proto, "toUpperCase", &nat_str_toupper);
    def_method(vm, vm.string_proto, "toLowerCase", &nat_str_tolower);
    def_method(vm, vm.string_proto, "trim", &nat_str_trim);
    def_method(vm, vm.string_proto, "split", &nat_str_split);
    def_method(vm, vm.string_proto, "repeat", &nat_str_repeat);
    def_method(vm, vm.string_proto, "padStart", &nat_str_padstart);
    def_method(vm, vm.string_proto, "padEnd", &nat_str_padend);
    def_method(vm, vm.string_proto, "replace", &nat_str_replace_x);
    def_method(vm, vm.string_proto, "replaceAll", &nat_str_replaceall);
    def_method(vm, vm.string_proto, "toString", &nat_str_tostring);
    def_method(vm, vm.string_proto, "valueOf", &nat_str_tostring);
    def_method(vm, vm.string_proto, "at", &nat_str_at);
    def_method(vm, vm.string_proto, "concat", &nat_str_concat);
    def_method(vm, vm.string_proto, "trimStart", &nat_str_trimstart);
    def_method(vm, vm.string_proto, "trimEnd", &nat_str_trimend);
    def_method(vm, vm.string_proto, "substr", &nat_str_substr);
    def_method(vm, vm.string_proto, "localeCompare", &nat_str_localecompare);
    def_method(vm, vm.string_proto, "normalize", &nat_str_normalize);
    def_method(vm, vm.string_proto, "toLocaleUpperCase", &nat_str_toupper);
    def_method(vm, vm.string_proto, "toLocaleLowerCase", &nat_str_tolower);
    def_method(vm, vm.string_proto, "split", &nat_str_split_x);
    def_method(vm, vm.string_proto, "match", &nat_str_match);
    def_method(vm, vm.string_proto, "matchAll", &nat_str_matchall);
    def_method(vm, vm.string_proto, "search", &nat_str_search);

    // Number / Boolean
    JsNative* number_ctor = def_global_fn(vm, "Number", &nat_number_ctor);
    props_set(&number_ctor.props, vm.atom_prototype, value_cell(&vm.number_proto.head));
    def_static(vm, number_ctor, "isInteger", &nat_num_isinteger);
    def_static(vm, number_ctor, "isFinite", &nat_num_isfinite);
    def_static(vm, number_ctor, "isSafeInteger", &nat_num_issafeinteger);
    def_static(vm, number_ctor, "isNaN", &nat_num_isnan);
    def_static(vm, number_ctor, "parseInt", &nat_parseint);
    def_static(vm, number_ctor, "parseFloat", &nat_parsefloat);
    props_set(&number_ctor.props, bi_atom(vm, "MAX_SAFE_INTEGER"), value_number(9007199254740991.0));
    props_set(&number_ctor.props, bi_atom(vm, "MIN_SAFE_INTEGER"), value_number(-9007199254740991.0));
    props_set(&number_ctor.props, bi_atom(vm, "EPSILON"), value_number(2.220446049250313e-16));
    props_set(&number_ctor.props, bi_atom(vm, "POSITIVE_INFINITY"), value_number(1.0e308 * 10.0));
    props_set(&number_ctor.props, bi_atom(vm, "NEGATIVE_INFINITY"), value_number(-1.0e308 * 10.0));
    props_set(&number_ctor.props, bi_atom(vm, "NaN"), value_number(0.0 / 0.0));
    def_method(vm, vm.number_proto, "toFixed", &nat_num_tofixed);
    def_method(vm, vm.number_proto, "toString", &nat_num_tostring);
    def_method(vm, vm.number_proto, "toExponential", &nat_num_toexponential);
    def_method(vm, vm.number_proto, "toPrecision", &nat_num_toprecision);
    def_method(vm, vm.number_proto, "toLocaleString", &nat_num_tolocalestring);
    def_method(vm, vm.number_proto, "valueOf", &nat_num_valueof);

    JsNative* boolean_ctor = def_global_fn(vm, "Boolean", &nat_boolean_ctor);
    props_set(&boolean_ctor.props, vm.atom_prototype, value_cell(&vm.boolean_proto.head));

    // Math
    JsObject* math_obj = js_new_object(&vm.heap, vm.object_proto);
    vm_set_global(vm, "Math", value_cell(&math_obj.head));
    def_value(vm, math_obj, "PI", value_number(PI));
    def_value(vm, math_obj, "E", value_number(E));
    def_method(vm, math_obj, "floor", &nat_math_floor);
    def_method(vm, math_obj, "ceil", &nat_math_ceil);
    def_method(vm, math_obj, "round", &nat_math_round);
    def_method(vm, math_obj, "trunc", &nat_math_trunc);
    def_method(vm, math_obj, "abs", &nat_math_abs);
    def_method(vm, math_obj, "sign", &nat_math_sign);
    def_method(vm, math_obj, "sqrt", &nat_math_sqrt);
    def_method(vm, math_obj, "cbrt", &nat_math_cbrt);
    def_method(vm, math_obj, "pow", &nat_math_pow);
    def_method(vm, math_obj, "exp", &nat_math_exp);
    def_method(vm, math_obj, "log", &nat_math_log);
    def_method(vm, math_obj, "log2", &nat_math_log2);
    def_method(vm, math_obj, "log10", &nat_math_log10);
    def_method(vm, math_obj, "sin", &nat_math_sin);
    def_method(vm, math_obj, "cos", &nat_math_cos);
    def_method(vm, math_obj, "tan", &nat_math_tan);
    def_method(vm, math_obj, "asin", &nat_math_asin);
    def_method(vm, math_obj, "acos", &nat_math_acos);
    def_method(vm, math_obj, "atan", &nat_math_atan);
    def_method(vm, math_obj, "atan2", &nat_math_atan2);
    def_method(vm, math_obj, "hypot", &nat_math_hypot);
    def_method(vm, math_obj, "sinh", &nat_math_sinh);
    def_method(vm, math_obj, "cosh", &nat_math_cosh);
    def_method(vm, math_obj, "tanh", &nat_math_tanh);
    def_method(vm, math_obj, "asinh", &nat_math_asinh);
    def_method(vm, math_obj, "acosh", &nat_math_acosh);
    def_method(vm, math_obj, "atanh", &nat_math_atanh);
    def_method(vm, math_obj, "log1p", &nat_math_log1p);
    def_method(vm, math_obj, "expm1", &nat_math_expm1);
    def_method(vm, math_obj, "fround", &nat_math_fround);
    def_method(vm, math_obj, "imul", &nat_math_imul);
    def_method(vm, math_obj, "clz32", &nat_math_clz32);
    def_method(vm, math_obj, "min", &nat_math_min);
    def_method(vm, math_obj, "max", &nat_math_max);
    def_method(vm, math_obj, "random", &nat_math_random);
    def_value(vm, math_obj, "LN2", value_number(0.6931471805599453));
    def_value(vm, math_obj, "LN10", value_number(2.302585092994046));
    def_value(vm, math_obj, "LOG2E", value_number(1.4426950408889634));
    def_value(vm, math_obj, "LOG10E", value_number(0.4342944819032518));
    def_value(vm, math_obj, "SQRT2", value_number(1.4142135623730951));
    def_value(vm, math_obj, "SQRT1_2", value_number(0.7071067811865476));

    // JSON
    JsObject* json_obj = js_new_object(&vm.heap, vm.object_proto);
    vm_set_global(vm, "JSON", value_cell(&json_obj.head));
    def_method(vm, json_obj, "stringify", &nat_json_stringify);
    def_method(vm, json_obj, "parse", &nat_json_parse);

    // Function.prototype
    def_method(vm, vm.function_proto, "call", &nat_fn_call);
    def_method(vm, vm.function_proto, "apply", &nat_fn_apply);
    def_method(vm, vm.function_proto, "bind", &nat_fn_bind);

    // Errors
    JsNative* err_ctor = def_global_fn(vm, "Error", &nat_error_ctor);
    props_set(&err_ctor.props, vm.atom_prototype, value_cell(&vm.error_protos[ERR_ERROR].head));
    JsNative* te_ctor = def_global_fn(vm, "TypeError", &nat_typeerror_ctor);
    props_set(&te_ctor.props, vm.atom_prototype, value_cell(&vm.error_protos[ERR_TYPE].head));
    JsNative* re_ctor = def_global_fn(vm, "RangeError", &nat_rangeerror_ctor);
    props_set(&re_ctor.props, vm.atom_prototype, value_cell(&vm.error_protos[ERR_RANGE].head));
    JsNative* fe_ctor = def_global_fn(vm, "ReferenceError", &nat_referror_ctor);
    props_set(&fe_ctor.props, vm.atom_prototype, value_cell(&vm.error_protos[ERR_REF].head));
    JsNative* se_ctor = def_global_fn(vm, "SyntaxError", &nat_syntaxerror_ctor);
    props_set(&se_ctor.props, vm.atom_prototype, value_cell(&vm.error_protos[ERR_SYNTAX].head));
    for i32 i = 0; i < 5; i++ {
        JsObject* ep = vm.error_protos[i];
        Value nm = new_str(vm, vm_error_kind_name(i));
        js_set_prop(ep, vm.atom_name, nm);
        Value em = new_str(vm, "");
        js_set_prop(ep, vm.atom_message, em);
        def_method(vm, ep, "toString", &nat_error_tostring);
    }

    // globals
    ignore def_global_fn(vm, "structuredClone", &nat_structured_clone);
    ignore def_global_fn(vm, "encodeURIComponent", &nat_encode_uri_comp);
    ignore def_global_fn(vm, "encodeURI", &nat_encode_uri);
    ignore def_global_fn(vm, "decodeURIComponent", &nat_decode_uri_comp);
    ignore def_global_fn(vm, "decodeURI", &nat_decode_uri);
    ignore def_global_fn(vm, "parseInt", &nat_parseint);
    ignore def_global_fn(vm, "parseFloat", &nat_parsefloat);
    ignore def_global_fn(vm, "isNaN", &nat_global_isnan);
    ignore def_global_fn(vm, "isFinite", &nat_global_isfinite);

    // Symbol
    JsNative* symbol_ctor = def_global_fn(vm, "Symbol", &nat_symbol_ctor);
    props_set(&symbol_ctor.props, bi_atom(vm, "iterator"), vm.sym_iterator);
    vm.symbol_proto = js_new_object(&vm.heap, vm.object_proto);
    props_set(&symbol_ctor.props, vm.atom_prototype, value_cell(&vm.symbol_proto.head));
    def_method(vm, vm.symbol_proto, "toString", &nat_symbol_tostring);
    def_method(vm, vm.symbol_proto, "valueOf", &nat_symbol_valueof);
    def_accessor(vm, vm.symbol_proto, "description", &nat_symbol_description);
    link_ctor(vm, vm.symbol_proto, symbol_ctor);

    // Array/String iterators via Symbol.iterator
    u32 iter_id = vm_sym_iterator_id(vm);
    JsNative* arr_it = js_new_native(&vm.heap, &nat_arr_symiter, "[Symbol.iterator]");
    js_set_prop(vm.array_proto, iter_id, value_cell(&arr_it.head));
    JsNative* str_it = js_new_native(&vm.heap, &nat_arr_symiter, "[Symbol.iterator]");
    js_set_prop(vm.string_proto, iter_id, value_cell(&str_it.head));

    // Generator.prototype
    vm.generator_proto = js_new_object(&vm.heap, vm.object_proto);
    def_method(vm, vm.generator_proto, "next", &nat_gen_next);
    def_method(vm, vm.generator_proto, "return", &nat_gen_return);
    def_method(vm, vm.generator_proto, "throw", &nat_gen_throw);
    JsNative* gen_it = js_new_native(&vm.heap, &nat_gen_symiter, "[Symbol.iterator]");
    js_set_prop(vm.generator_proto, iter_id, value_cell(&gen_it.head));

    // Promise
    vm.promise_proto = js_new_object(&vm.heap, vm.object_proto);
    JsNative* promise_ctor = def_global_fn(vm, "Promise", &nat_promise_ctor);
    props_set(&promise_ctor.props, vm.atom_prototype, value_cell(&vm.promise_proto.head));
    def_static(vm, promise_ctor, "resolve", &nat_promise_resolve);
    def_static(vm, promise_ctor, "reject", &nat_promise_reject);
    def_static(vm, promise_ctor, "all", &nat_promise_all);
    def_static(vm, promise_ctor, "race", &nat_promise_race);
    def_method(vm, vm.promise_proto, "then", &nat_promise_then);
    def_method(vm, vm.promise_proto, "catch", &nat_promise_catch);
    def_method(vm, vm.promise_proto, "finally", &nat_promise_finally);

    // Map
    vm.map_proto = js_new_object(&vm.heap, vm.object_proto);
    JsNative* map_ctor = def_global_fn(vm, "Map", &nat_map_ctor);
    props_set(&map_ctor.props, vm.atom_prototype, value_cell(&vm.map_proto.head));
    def_method(vm, vm.map_proto, "set", &nat_map_set);
    def_method(vm, vm.map_proto, "get", &nat_map_get);
    def_method(vm, vm.map_proto, "has", &nat_map_has);
    def_method(vm, vm.map_proto, "delete", &nat_map_delete);
    def_method(vm, vm.map_proto, "clear", &nat_map_clear);
    def_method(vm, vm.map_proto, "forEach", &nat_map_foreach);
    def_method(vm, vm.map_proto, "keys", &nat_map_keys);
    def_method(vm, vm.map_proto, "values", &nat_map_values);
    def_method(vm, vm.map_proto, "entries", &nat_map_entries);
    def_accessor(vm, vm.map_proto, "size", &nat_map_size);
    JsNative* map_it = js_new_native(&vm.heap, &nat_map_entries, "[Symbol.iterator]");
    js_set_prop(vm.map_proto, iter_id, value_cell(&map_it.head));

    // Set
    vm.set_proto = js_new_object(&vm.heap, vm.object_proto);
    JsNative* set_ctor = def_global_fn(vm, "Set", &nat_set_ctor);
    props_set(&set_ctor.props, vm.atom_prototype, value_cell(&vm.set_proto.head));
    def_method(vm, vm.set_proto, "add", &nat_set_add);
    def_method(vm, vm.set_proto, "has", &nat_map_has);
    def_method(vm, vm.set_proto, "delete", &nat_map_delete);
    def_method(vm, vm.set_proto, "clear", &nat_map_clear);
    def_method(vm, vm.set_proto, "forEach", &nat_map_foreach);
    def_method(vm, vm.set_proto, "keys", &nat_map_keys);
    def_method(vm, vm.set_proto, "values", &nat_map_values);
    def_method(vm, vm.set_proto, "entries", &nat_map_entries);
    def_accessor(vm, vm.set_proto, "size", &nat_map_size);
    JsNative* set_it = js_new_native(&vm.heap, &nat_map_values, "[Symbol.iterator]");
    js_set_prop(vm.set_proto, iter_id, value_cell(&set_it.head));

    // Date
    vm.date_proto = js_new_object(&vm.heap, vm.object_proto);
    JsNative* date_ctor = def_global_fn(vm, "Date", &nat_date_ctor);
    props_set(&date_ctor.props, vm.atom_prototype, value_cell(&vm.date_proto.head));
    def_static(vm, date_ctor, "now", &nat_date_now);
    def_static(vm, date_ctor, "UTC", &nat_date_utc);
    def_method(vm, vm.date_proto, "getTime", &nat_date_gettime);
    def_method(vm, vm.date_proto, "valueOf", &nat_date_gettime);
    def_method(vm, vm.date_proto, "getFullYear", &nat_date_getfullyear);
    def_method(vm, vm.date_proto, "getMonth", &nat_date_getmonth);
    def_method(vm, vm.date_proto, "getDate", &nat_date_getdate);
    def_method(vm, vm.date_proto, "getDay", &nat_date_getday);
    def_method(vm, vm.date_proto, "getHours", &nat_date_gethours);
    def_method(vm, vm.date_proto, "getMinutes", &nat_date_getminutes);
    def_method(vm, vm.date_proto, "getSeconds", &nat_date_getseconds);
    def_method(vm, vm.date_proto, "getMilliseconds", &nat_date_getms);
    // no timezone support: the UTC accessors alias the plain ones
    def_method(vm, vm.date_proto, "getUTCFullYear", &nat_date_getfullyear);
    def_method(vm, vm.date_proto, "getUTCMonth", &nat_date_getmonth);
    def_method(vm, vm.date_proto, "getUTCDate", &nat_date_getdate);
    def_method(vm, vm.date_proto, "getUTCDay", &nat_date_getday);
    def_method(vm, vm.date_proto, "getUTCHours", &nat_date_gethours);
    def_method(vm, vm.date_proto, "getUTCMinutes", &nat_date_getminutes);
    def_method(vm, vm.date_proto, "getUTCSeconds", &nat_date_getseconds);
    def_method(vm, vm.date_proto, "getUTCMilliseconds", &nat_date_getms);
    def_method(vm, vm.date_proto, "toISOString", &nat_date_toiso);
    def_method(vm, vm.date_proto, "toJSON", &nat_date_toiso);

    // RegExp
    vm.regexp_proto = js_new_object(&vm.heap, vm.object_proto);
    JsNative* regexp_ctor = def_global_fn(vm, "RegExp", &nat_regexp_ctor);
    props_set(&regexp_ctor.props, vm.atom_prototype, value_cell(&vm.regexp_proto.head));
    def_method(vm, vm.regexp_proto, "test", &nat_regexp_test);
    def_method(vm, vm.regexp_proto, "exec", &nat_regexp_exec);
    def_method(vm, vm.regexp_proto, "toString", &nat_regexp_tostring);

    // timers and microtasks
    ignore def_global_fn(vm, "setTimeout", &nat_set_timeout);
    ignore def_global_fn(vm, "clearTimeout", &nat_clear_timeout);
    ignore def_global_fn(vm, "setInterval", &nat_set_timeout);
    ignore def_global_fn(vm, "clearInterval", &nat_clear_timeout);
    ignore def_global_fn(vm, "queueMicrotask", &nat_queue_microtask);

    // console.warn / console.info
    Value* cv = intmap_get<Value>(&vm.globals, bi_atom(vm, "console"));
    if cv != null && value_is_object(*cv) {
        JsObject* con = value_as_object(*cv);
        def_method(vm, con, "warn", &nat_console_warn);
        def_method(vm, con, "info", &nat_console_info);
    }

    // proto.constructor back-links
    link_ctor(vm, vm.object_proto, object_ctor);
    link_ctor(vm, vm.array_proto, array_ctor);
    link_ctor(vm, vm.string_proto, string_ctor);
    link_ctor(vm, vm.number_proto, number_ctor);
    link_ctor(vm, vm.boolean_proto, boolean_ctor);
    link_ctor(vm, vm.error_protos[ERR_ERROR], err_ctor);
    link_ctor(vm, vm.error_protos[ERR_TYPE], te_ctor);
    link_ctor(vm, vm.error_protos[ERR_RANGE], re_ctor);
    link_ctor(vm, vm.error_protos[ERR_REF], fe_ctor);
    link_ctor(vm, vm.error_protos[ERR_SYNTAX], se_ctor);
    link_ctor(vm, vm.promise_proto, promise_ctor);
    link_ctor(vm, vm.map_proto, map_ctor);
    link_ctor(vm, vm.set_proto, set_ctor);
    link_ctor(vm, vm.date_proto, date_ctor);
    link_ctor(vm, vm.regexp_proto, regexp_ctor);

    // globalThis: an object mirroring the global bindings. Snapshotting
    // the built-ins (rather than routing every property access to the
    // globals table) keeps the hot property path untouched; this matches
    // module scoping, where top-level declarations are not global props.
    JsObject* gt = js_new_object(&vm.heap, vm.object_proto);
    for i32 i = 0; i < vm.globals.cap; i++ {
        IntSlot<Value>* sl = vm.globals.slots + i;
        if sl.state == SLOT_USED {
            props_set_desc(&gt.props, sl.key, sl.val, METHOD_ATTRS);
        }
    }
    Value gtv = value_cell(&gt.head);
    props_set_desc(&gt.props, bi_atom(vm, "globalThis"), gtv, METHOD_ATTRS);
    vm_set_global(vm, "globalThis", gtv);
}

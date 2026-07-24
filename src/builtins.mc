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
import bigint;
import vm;
import math;
import file;
import deflate;
import inflate;
import net_os;
import tls_native;
import tls_chain;
import "tls/picotls.mc";   // cifra SHA-384/512 for the crypto module's digests

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
else when os(linux) {
    extern "libm.so.6" f64 sinh(f64 x);
    extern "libm.so.6" f64 cosh(f64 x);
    extern "libm.so.6" f64 tanh(f64 x);
    extern "libm.so.6" f64 asinh(f64 x);
    extern "libm.so.6" f64 acosh(f64 x);
    extern "libm.so.6" f64 atanh(f64 x);
    extern "libm.so.6" f64 log1p(f64 x);
    extern "libm.so.6" f64 expm1(f64 x);
}
else when os(android) {
    extern "libm.so" f64 sinh(f64 x);
    extern "libm.so" f64 cosh(f64 x);
    extern "libm.so" f64 tanh(f64 x);
    extern "libm.so" f64 asinh(f64 x);
    extern "libm.so" f64 acosh(f64 x);
    extern "libm.so" f64 atanh(f64 x);
    extern "libm.so" f64 log1p(f64 x);
    extern "libm.so" f64 expm1(f64 x);
}
else when os(macos) || os(ios) {
    extern "libSystem.B.dylib" f64 sinh(f64 x);
    extern "libSystem.B.dylib" f64 cosh(f64 x);
    extern "libSystem.B.dylib" f64 tanh(f64 x);
    extern "libSystem.B.dylib" f64 asinh(f64 x);
    extern "libSystem.B.dylib" f64 acosh(f64 x);
    extern "libSystem.B.dylib" f64 atanh(f64 x);
    extern "libSystem.B.dylib" f64 log1p(f64 x);
    extern "libSystem.B.dylib" f64 expm1(f64 x);
}
else when os(wasm) {
    // No libm to link against: the standard identities over the exp /
    // log / sqrt builtins. log1p/expm1 lose the small-x accuracy the
    // libm versions have, which Math.log1p/expm1 inherit here.
    private f64 sinh(f64 x) { return (exp(x) - exp(0.0 - x)) / 2.0; }
    private f64 cosh(f64 x) { return (exp(x) + exp(0.0 - x)) / 2.0; }
    private f64 tanh(f64 x) { return sinh(x) / cosh(x); }
    private f64 asinh(f64 x) { return log(x + sqrt(x * x + 1.0)); }
    private f64 acosh(f64 x) { return log(x + sqrt(x * x - 1.0)); }
    private f64 atanh(f64 x) { return 0.5 * log((1.0 + x) / (1.0 - x)); }
    private f64 log1p(f64 x) { return log(1.0 + x); }
    private f64 expm1(f64 x) { return exp(x) - 1.0; }
}
else {
    // No arm for this target. Add a `when os(...)` arm above rather
    // than letting it fall back to another platform's libm.
    tsmc_unsupported_target__add_a_when_os_arm _unsupported_math;
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

// ToIntegerOrInfinity truncated toward zero and saturated to the i32 range.
// A plain (i32) cast of +/-Infinity or an out-of-range magnitude overflows
// (Infinity casts to 0), which silently corrupts a length-relative index —
// e.g. slice(1, Infinity) would compute end 0 and return nothing. Saturating
// lets the subsequent clamp-to-length do the right thing. Only for indices
// that are later clamped against a length, never for allocation sizes.
private i32 to_int_sat(Value v) {
    f64 d = js_to_number(v);
    if d != d { return 0; }
    if d >= 2147483647.0 { return 2147483647; }
    if d <= -2147483648.0 { return -2147483648; }
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

// Enumerable string keys of a proxy (via the ownKeys trap) paired with their
// trapped values — the shared path for Object.values/entries/assign so a
// proxy source is never read as its (empty) own props.
private JsObject* proxy_enum_keys(VM* vm, Value ov) {
    return vm_own_keys(vm, ov);
}

private Value nat_object_values(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    JsObject* arr = js_new_array(&vm.heap, vm.array_proto);
    i32 rm = gc_root_mark(&vm.heap);
    gc_root(&vm.heap, value_cell(&arr.head));
    Value ov = arg_at(args, argc, 0);
    if value_is_object(ov) && (value_as_object(ov).obj_flags & OBJF_PROXY) != 0 {
        JsObject* keys = proxy_enum_keys(vm, ov);
        gc_root(&vm.heap, value_cell(&keys.head));
        for i32 i = 0; i < keys.elen; i++ {
            Value kv = js_array_get(keys, i);
            Value pv;
            ignore vm_get_prop_value(vm, ov, atom_intern(&vm.atoms, sview(kv)), &pv);
            js_array_set(arr, i, pv);
        }
        gc_root_reset(&vm.heap, rm);
        return value_cell(&arr.head);
    }
    if value_is_object(ov) {
        JsObject* o = value_as_object(ov);
        i32 n = 0;
        if (o.obj_flags & OBJF_ARRAY) != 0 {
            for i32 i = 0; i < o.elen; i++ {
                if !js_array_has(o, i) { continue; }
                js_array_set(arr, n, js_array_get(o, i));
                n++;
            }
        } else if (o.obj_flags & OBJF_TYPEDARRAY) != 0 {
            i32 len = ta_len(vm, o);
            for i32 i = 0; i < len; i++ {
                js_array_set(arr, n, vm_ta_get(vm, o, i));
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
    if value_is_object(ov) && (value_as_object(ov).obj_flags & OBJF_PROXY) != 0 {
        JsObject* keys = proxy_enum_keys(vm, ov);
        gc_root(&vm.heap, value_cell(&keys.head));
        for i32 i = 0; i < keys.elen; i++ {
            Value kv = js_array_get(keys, i);
            Value pv;
            ignore vm_get_prop_value(vm, ov, atom_intern(&vm.atoms, sview(kv)), &pv);
            JsObject* pair = js_new_array(&vm.heap, vm.array_proto);
            js_array_set(arr, i, value_cell(&pair.head));
            js_array_set(pair, 0, kv);
            js_array_set(pair, 1, pv);
        }
        gc_root_reset(&vm.heap, rm);
        return value_cell(&arr.head);
    }
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
        } else if (o.obj_flags & OBJF_TYPEDARRAY) != 0 {
            i32 len = ta_len(vm, o);
            for i32 i = 0; i < len; i++ {
                JsObject* pair = js_new_array(&vm.heap, vm.array_proto);
                js_array_set(arr, n, value_cell(&pair.head));
                string s = format("{}", i);
                Value ks = new_str(vm, s);
                free(s);
                js_array_set(pair, 0, ks);
                js_array_set(pair, 1, vm_ta_get(vm, o, i));
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
        if (src.obj_flags & OBJF_PROXY) != 0 {
            // a proxy source: copy its enumerable keys through the get trap
            JsObject* keys = proxy_enum_keys(vm, sv2);
            i32 krm = gc_root_mark(&vm.heap);
            gc_root(&vm.heap, value_cell(&keys.head));
            for i32 i = 0; i < keys.elen; i++ {
                Value kv = js_array_get(keys, i);
                u32 pk = atom_intern(&vm.atoms, sview(kv));
                Value pv;
                ignore vm_get_prop_value(vm, sv2, pk, &pv);
                js_set_prop(t, pk, pv);
            }
            gc_root_reset(&vm.heap, krm);
            continue;
        }
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
        // an explicitly set [[Prototype]] (parent ctor or plain object / null),
        // else the default Function.prototype
        Value fp = value_as_function(ov).fproto;
        if value_is_function(fp) || value_is_native(fp) || value_is_object(fp) { return fp; }
        if value_is_null(fp) { return value_null(); }
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
    PropList* props = value_props(ov);
    bool is_arr = value_is_object(ov) && (value_as_object(ov).obj_flags & OBJF_ARRAY) != 0;
    if props != null {
        i32 n = 0;
        if is_arr {
            JsObject* o = value_as_object(ov);
            for i32 i = 0; i < o.elen; i++ {
                if !js_array_has(o, i) { continue; }
                string s = format("{}", i);
                Value ks = new_str(vm, s);
                free(s);
                js_array_set(arr, n, ks);
                n++;
            }
        }
        // functions list their synthesized length/name first
        if value_is_callable(ov) {
            js_array_set(arr, n, new_str(vm, "length"));
            n++;
            js_array_set(arr, n, new_str(vm, "name"));
            n++;
        }
        // all own string keys, enumerable or not, minus symbols and the
        // engine's %-internal slots
        for i32 i = 0; i < props.len; i++ {
            u32 key = (props.items + i).key;
            if (key & 0x80000000) != 0 { continue; }
            str nm = atom_name(&vm.atoms, key);
            if nm.len > 0 && *(nm.data) == '%' { continue; }
            js_array_set(arr, n, new_str(vm, nm));
            n++;
        }
        if is_arr {
            js_array_set(arr, n, new_str(vm, "length"));
        }
    }
    gc_root_reset(&vm.heap, rm);
    return value_cell(&arr.head);
}

// The mirror of getOwnPropertyNames: own symbol-keyed properties only.
private Value nat_object_getownsymbols(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    JsObject* arr = js_new_array(&vm.heap, vm.array_proto);
    i32 rm = gc_root_mark(&vm.heap);
    gc_root(&vm.heap, value_cell(&arr.head));
    PropList* props = value_props(arg_at(args, argc, 0));
    if props != null {
        i32 n = 0;
        for i32 i = 0; i < props.len; i++ {
            u32 key = (props.items + i).key;
            if (key & 0x80000000) == 0 { continue; }
            js_array_set(arr, n, atom_to_key(vm, key));
            n++;
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
    } else if value_is_function(ov) {
        // a function's [[Prototype]] is stored inline; accept a plain object,
        // another callable, or null (undefined means "unchanged").
        if value_is_object(pv) || value_is_function(pv) || value_is_native(pv) {
            value_as_function(ov).fproto = pv;
        } else if value_is_null(pv) {
            value_as_function(ov).fproto = value_null();
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
    // The receiver's own-property table: objects, functions, and natives each
    // carry one. Proxies trap; only objects can be proxies.
    PropList* props = null;
    if value_is_function(ov) {
        props = &value_as_function(ov).props;
    } else if value_is_native(ov) {
        props = &value_as_native(ov).props;
    } else if value_is_object(ov) {
        JsObject* o = value_as_object(ov);
        if (o.obj_flags & OBJF_PROXY) != 0 {
            JsProxy* p = cast(JsProxy*, o);
            Value trap = proxy_trap_fn(vm, p, "defineProperty");
            if value_is_callable(trap) {
                i32 rmp = gc_root_mark(&vm.heap);
                noinit Value[3] ca;
                ca[0] = p.target;
                ca[1] = arg_at(args, argc, 1);
                ca[2] = arg_at(args, argc, 2);
                ignore vm_call_value(vm, trap, p.handler, &ca[0], 3);
                gc_root_reset(&vm.heap, rmp);
                return ov;
            }
            // default: defineProperty(target, key, desc)
            noinit Value[3] ca;
            ca[0] = p.target;
            ca[1] = arg_at(args, argc, 1);
            ca[2] = arg_at(args, argc, 2);
            ignore nat_object_defineproperty(vmp, callee, thisv, &ca[0], 3);
            return ov;
        }
        props = &o.props;
    } else {
        vm_throw_error(vm, ERR_TYPE, "Object.defineProperty called on non-object");
        return value_undefined();
    }
    i32 rm = gc_root_mark(&vm.heap);
    // a Symbol is a valid property key, so take the reflection key path
    // rather than a plain ToString (which throws on a Symbol)
    str sk;
    u32 key = reflect_key(vm, arg_at(args, argc, 1), &sk);
    if vm.has_pending { gc_root_reset(&vm.heap, rm); return value_undefined(); }
    Value desc = arg_at(args, argc, 2);
    if !value_is_object(desc) {
        gc_root_reset(&vm.heap, rm);
        vm_throw_error(vm, ERR_TYPE, "property description must be an object");
        return value_undefined();
    }

    // start from the existing attributes, or all-false for a new property
    Prop* existing = props_entry(props, key);
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
    props_set_desc(props, key, stored, flags);
    gc_root_reset(&vm.heap, rm);
    return ov;
}

private Value nat_object_defineproperties(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    Value ov = arg_at(args, argc, 0);
    Value props = arg_at(args, argc, 1);
    // per-key defineProperty handles object/function/native receivers
    bool ok_target = value_is_object(ov) || value_is_function(ov) || value_is_native(ov);
    if !ok_target || !value_is_object(props) { return ov; }
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

// Property-key value → atom for reflection APIs: Symbols map to their
// reserved id, everything else is ToString'd. `sk` receives the string
// form (for the array index/length checks); it is left empty for symbols.
private u32 reflect_key(VM* vm, Value kv, str* sk) {
    if value_is_symbol(kv) {
        *sk = "";
        return value_as_symbol(kv).id;
    }
    Value ks = js_to_string_value(vm, kv);
    vm_push(vm, ks);
    u32 a = atom_intern(&vm.atoms, sview(ks));
    *sk = atom_name(&vm.atoms, a);
    vm_pop(vm);
    return a;
}

// A function's `length` and `name` are own properties synthesized from
// its template rather than stored. Returns true (with the value) for
// those keys on a callable, so reflection reports them like real props.
private bool fn_own_synth(VM* vm, Value ov, u32 key, Value* out) {
    if !value_is_callable(ov) { return false; }
    if key != vm.atom_length && key != vm.atom_name { return false; }
    return vm_get_prop_value(vm, ov, key, out);
}

private Value nat_object_getownpropdesc(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    Value ov = arg_at(args, argc, 0);
    if value_is_object(ov) && (value_as_object(ov).obj_flags & OBJF_PROXY) != 0 {
        JsProxy* p = cast(JsProxy*, value_as_object(ov));
        Value keyv = arg_at(args, argc, 1);
        Value trap = proxy_trap_fn(vm, p, "getOwnPropertyDescriptor");
        noinit Value[2] ca;
        ca[0] = p.target;
        if value_is_callable(trap) {
            i32 rmp = gc_root_mark(&vm.heap);
            ca[1] = keyv;
            Value d = vm_call_value(vm, trap, p.handler, &ca[0], 2);
            gc_root_reset(&vm.heap, rmp);
            return d;
        }
        // default: getOwnPropertyDescriptor(target, key)
        ca[1] = keyv;
        return nat_object_getownpropdesc(vmp, callee, thisv, &ca[0], 2);
    }
    PropList* props = value_props(ov);
    if props == null { return value_undefined(); }
    i32 rm = gc_root_mark(&vm.heap);
    str kname;
    u32 key = reflect_key(vm, arg_at(args, argc, 1), &kname);
    if vm.has_pending { gc_root_reset(&vm.heap, rm); return value_undefined(); }

    // array index / length live outside the property table
    if value_is_object(ov) && (value_as_object(ov).obj_flags & OBJF_ARRAY) != 0 {
        JsObject* o = value_as_object(ov);
        bool is_len = str_equal(kname, "length");
        i32 idx = -1;
        if !is_len && kname.len > 0 {
            f64 nv = js_string_to_number(kname);
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

    Prop* pe = props_entry(props, key);
    if pe == null {
        // functions expose synthesized length/name
        Value fv;
        if fn_own_synth(vm, ov, key, &fv) {
            gc_root(&vm.heap, fv);
            JsObject* fd = js_new_object(&vm.heap, vm.object_proto);
            gc_root(&vm.heap, value_cell(&fd.head));
            js_set_prop(fd, bi_atom(vm, "value"), fv);
            js_set_prop(fd, bi_atom(vm, "writable"), value_bool(false));
            js_set_prop(fd, bi_atom(vm, "enumerable"), value_bool(false));
            js_set_prop(fd, bi_atom(vm, "configurable"), value_bool(true));
            gc_root_reset(&vm.heap, rm);
            return value_cell(&fd.head);
        }
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

// Object.getOwnPropertyDescriptors(obj): a map of every own string key to its
// property descriptor, reusing the singular logic. Symbol-keyed properties are
// not included (matches getOwnPropertyNames enumeration).
private Value nat_object_getownpropdescs(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    Value ov = arg_at(args, argc, 0);
    i32 rm = gc_root_mark(&vm.heap);
    JsObject* result = js_new_object(&vm.heap, vm.object_proto);
    gc_root(&vm.heap, value_cell(&result.head));
    Value names = nat_object_getownnames(vmp, callee, thisv, args, argc);
    gc_root(&vm.heap, names);
    if value_is_object(names) {
        JsObject* arr = value_as_object(names);
        i32 n = arr.elen;
        for i32 i = 0; i < n; i++ {
            Value kv = js_array_get(arr, i);
            noinit Value[2] dargs;
            dargs[0] = ov;
            dargs[1] = kv;
            Value desc = nat_object_getownpropdesc(vmp, callee, thisv, &dargs[0], 2);
            if value_is_object(desc) {
                js_set_prop(result, atom_intern(&vm.atoms, sview(kv)), desc);
            }
        }
    }
    gc_root_reset(&vm.heap, rm);
    return value_cell(&result.head);
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

// Own-property existence, shared by Object.prototype.hasOwnProperty and
// Object.hasOwn. Array elements and an array's `length`, typed-array indices,
// and a string's indices and `length` all live outside the property table, so
// each is checked explicitly. The key is resolved to an atom first, so a
// string-form index (arr["0"]) answers the same as the numeric one.
private bool own_prop_exists(VM* vm, Value ov, Value kv) {
    str sk;
    u32 a = reflect_key(vm, kv, &sk);
    if vm.has_pending { return false; }

    if value_is_object(ov) {
        JsObject* o = value_as_object(ov);
        if (o.obj_flags & OBJF_ARRAY) != 0 {
            if a == vm.atom_length { return true; }
            i32 idx = ta_atom_index(vm, a);
            if idx >= 0 { return js_array_has(o, idx); }
        } else if (o.obj_flags & OBJF_TYPEDARRAY) != 0 {
            i32 idx = ta_atom_index(vm, a);
            if idx >= 0 { return idx < ta_len(vm, o); }
        }
    } else if value_is_string(ov) {
        if a == vm.atom_length { return true; }
        i32 idx = ta_atom_index(vm, a);
        if idx >= 0 { return idx < value_as_string(ov).u16len; }
    }

    PropList* props = value_props(ov);
    if props != null && props_get(props, a) != null { return true; }
    Value fv;
    return fn_own_synth(vm, ov, a, &fv);
}

private Value nat_has_own(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    return value_bool(own_prop_exists(vm, thisv, arg_at(args, argc, 0)));
}

// Object.prototype.propertyIsEnumerable: own AND enumerable.
private Value nat_property_is_enumerable(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    Value kv = arg_at(args, argc, 0);
    if value_is_object(thisv) && (value_as_object(thisv).obj_flags & OBJF_PROXY) != 0 {
        noinit Value[2] ca;
        ca[0] = thisv;
        ca[1] = kv;
        Value d = nat_object_getownpropdesc(vmp, callee, thisv, &ca[0], 2);
        if !value_is_object(d) { return value_bool(false); }
        Value en;
        ignore vm_get_prop_value(vm, d, bi_atom(vm, "enumerable"), &en);
        return value_bool(js_truthy(en));
    }
    str sk;
    u32 a = reflect_key(vm, kv, &sk);
    if vm.has_pending { return value_bool(false); }
    if value_is_object(thisv) && (value_as_object(thisv).obj_flags & OBJF_ARRAY) != 0 {
        i32 idx = ta_atom_index(vm, a);
        if idx >= 0 { return value_bool(js_array_has(value_as_object(thisv), idx)); }
    }
    PropList* props = value_props(thisv);
    if props == null { return value_bool(false); }
    Prop* pe = props_entry(props, a);
    if pe == null { return value_bool(false); }
    return value_bool((pe.flags & PROP_ENUMERABLE) != 0);
}

// True if `target` is on o's prototype chain (or is o's own proto).
private bool proto_chain_has(JsObject* o, JsObject* target) {
    if target == null { return false; }
    JsObject* c = o.proto;
    while c != null {
        if c == target { return true; }
        c = c.proto;
    }
    return false;
}

// Object.prototype.toString -> "[object <tag>]" with the correct builtin tag
// (Array/String/Number/.../Date/RegExp/Error), as many type-detection idioms
// depend on (e.g. `Object.prototype.toString.call(x) === '[object Array]'`).
private Value nat_object_tostring(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    str tag = "Object";
    if value_is_undefined(thisv) { tag = "Undefined"; }
    else if value_is_null(thisv) { tag = "Null"; }
    else if value_is_array(thisv) { tag = "Array"; }
    else if value_is_string(thisv) { tag = "String"; }
    else if value_is_number(thisv) { tag = "Number"; }
    else if value_is_bool(thisv) { tag = "Boolean"; }
    else if value_is_bigint(thisv) { tag = "BigInt"; }
    else if value_is_symbol(thisv) { tag = "Symbol"; }
    else if value_is_function(thisv) || value_is_native(thisv) { tag = "Function"; }
    else if value_is_object(thisv) {
        JsObject* o = value_as_object(thisv);
        if proto_chain_has(o, vm.regexp_proto) { tag = "RegExp"; }
        else if proto_chain_has(o, vm.date_proto) { tag = "Date"; }
        else if proto_chain_has(o, vm.error_protos[ERR_ERROR]) { tag = "Error"; }
    }
    str_buf sb;
    str_buf_init(&sb);
    str_buf_add(&sb, "[object ");
    str_buf_add(&sb, tag);
    str_buf_add(&sb, "]");
    Value r = new_str(vm, str_buf_to_str(&sb));
    str_buf_free(&sb);
    return r;
}

// --- Array ------------------------------------------------------------------

private JsObject* this_array(VM* vm, Value thisv) {
    if value_is_array(thisv) { return value_as_object(thisv); }
    vm_throw_error(vm, ERR_TYPE, "receiver is not an array");
    return null;
}

// Like this_array, but for the non-mutating methods: accepts any array-like
// receiver (an object with a numeric `length`) by materializing a real array
// from `length` + indexed reads. Real arrays are returned directly, so the
// common case is unchanged. Reads go through vm_get_prop_value, so the
// arguments object and `Array.prototype.slice.call(x)` work (and later a
// proxy's element reads trap). Only used by methods that do not mutate the
// receiver — mutating methods keep the strict this_array. Returns null (and
// throws) if the receiver is neither an array nor array-like.
private JsObject* this_arraylike(VM* vm, Value thisv) {
    if value_is_array(thisv) { return value_as_object(thisv); }
    if value_is_object(thisv) {
        Value lv;
        if vm_get_prop_value(vm, thisv, vm.atom_length, &lv) {
            f64 lf = js_to_number(lv);
            if lf >= 0.0 {
                i32 len = cast(i32, lf);
                i32 rm = gc_root_mark(&vm.heap);
                JsObject* a = js_new_array(&vm.heap, vm.array_proto);
                gc_root(&vm.heap, value_cell(&a.head));
                for i32 i = 0; i < len; i++ {
                    Value ev;
                    if !vm_get_prop_value(vm, thisv, index_atom(vm, i), &ev) { ev = value_undefined(); }
                    if vm.has_pending { gc_root_reset(&vm.heap, rm); return null; }
                    js_array_set(a, i, ev);
                }
                gc_root_reset(&vm.heap, rm);
                return a;
            }
        }
    }
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

// True iff v is an array, looking through any chain of proxies. This is the
// IsArray the spec uses, so Array.isArray and JSON serialization agree: a
// proxy wrapping an array serializes as an array.
private bool is_array_pierced(Value v) {
    while value_is_object(v) && (value_as_object(v).obj_flags & OBJF_PROXY) != 0 {
        v = cast(JsProxy*, value_as_object(v)).target;
    }
    return value_is_array(v);
}

private Value nat_array_isarray(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    return value_bool(is_array_pierced(arg_at(args, argc, 0)));
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

// --- generic mutating Array methods ----------------------------------------
// The spec defines the mutating Array methods over `this` in terms of
// Get/Set/Delete, so they must also work on an array-like or a Proxy (whose
// traps then fire, which is what immer's array drafts rely on). A real array
// keeps the direct element-storage fast path below; anything else that is an
// object routes through these helpers. A non-object receiver still gets the
// loud refusal from this_array.

private bool needs_generic_array(Value thisv) {
    return !value_is_array(thisv) && value_is_object(thisv);
}

private i32 al_length(VM* vm, Value recv) {
    Value lv;
    if !vm_get_prop_value(vm, recv, vm.atom_length, &lv) { return 0; }
    f64 lf = js_to_number(lv);
    if lf != lf || lf < 0.0 { return 0; }
    if lf > 2147483647.0 { return 2147483647; }
    return cast(i32, lf);
}

private void al_set_length(VM* vm, Value recv, i32 n) {
    ignore vm_set_prop_value(vm, recv, vm.atom_length, value_int(n));
}

private Value al_get(VM* vm, Value recv, i32 i) {
    Value v;
    if !vm_get_prop_value(vm, recv, index_atom(vm, i), &v) { return value_undefined(); }
    return v;
}

private void al_set(VM* vm, Value recv, i32 i, Value v) {
    ignore vm_set_prop_value(vm, recv, index_atom(vm, i), v);
}

private void al_del(VM* vm, Value recv, i32 i) {
    ignore vm_delete_prop_value(vm, recv, index_atom(vm, i));
}

private Value arr_push_generic(VM* vm, Value recv, Value* args, i32 argc) {
    i32 len = al_length(vm, recv);
    for i32 i = 0; i < argc; i++ {
        al_set(vm, recv, len, *(args + i));
        if vm.has_pending { return value_undefined(); }
        len++;
    }
    al_set_length(vm, recv, len);
    return value_int(len);
}

private Value arr_pop_generic(VM* vm, Value recv) {
    i32 len = al_length(vm, recv);
    if len == 0 {
        al_set_length(vm, recv, 0);
        return value_undefined();
    }
    Value v = al_get(vm, recv, len - 1);
    if vm.has_pending { return value_undefined(); }
    al_del(vm, recv, len - 1);
    al_set_length(vm, recv, len - 1);
    return v;
}

private Value arr_shift_generic(VM* vm, Value recv) {
    i32 len = al_length(vm, recv);
    if len == 0 {
        al_set_length(vm, recv, 0);
        return value_undefined();
    }
    Value first = al_get(vm, recv, 0);
    for i32 i = 1; i < len; i++ {
        al_set(vm, recv, i - 1, al_get(vm, recv, i));
        if vm.has_pending { return value_undefined(); }
    }
    al_del(vm, recv, len - 1);
    al_set_length(vm, recv, len - 1);
    return first;
}

private Value arr_unshift_generic(VM* vm, Value recv, Value* args, i32 argc) {
    i32 len = al_length(vm, recv);
    for i32 i = len - 1; i >= 0; i-- {
        al_set(vm, recv, i + argc, al_get(vm, recv, i));
        if vm.has_pending { return value_undefined(); }
    }
    for i32 i = 0; i < argc; i++ {
        al_set(vm, recv, i, *(args + i));
        if vm.has_pending { return value_undefined(); }
    }
    al_set_length(vm, recv, len + argc);
    return value_int(len + argc);
}

private Value arr_reverse_generic(VM* vm, Value recv) {
    i32 len = al_length(vm, recv);
    for i32 i = 0; i < len / 2; i++ {
        i32 j = len - 1 - i;
        Value a = al_get(vm, recv, i);
        Value b = al_get(vm, recv, j);
        al_set(vm, recv, i, b);
        al_set(vm, recv, j, a);
        if vm.has_pending { return value_undefined(); }
    }
    return recv;
}

private Value arr_fill_generic(VM* vm, Value recv, Value* args, i32 argc) {
    i32 len = al_length(vm, recv);
    Value v = arg_at(args, argc, 0);
    i32 start = argc > 1 ? rel_index(to_int_sat(*(args + 1)), len) : 0;
    i32 end = argc > 2 && !value_is_undefined(*(args + 2))
        ? rel_index(to_int_sat(*(args + 2)), len) : len;
    for i32 i = start; i < end; i++ {
        al_set(vm, recv, i, v);
        if vm.has_pending { return value_undefined(); }
    }
    return recv;
}

private Value arr_splice_generic(VM* vm, Value recv, Value* args, i32 argc) {
    i32 len = al_length(vm, recv);
    i32 start = rel_index(argc > 0 ? to_int_sat(*(args)) : 0, len);
    i32 del = len - start;
    if argc > 1 {
        del = to_int_sat(*(args + 1));
        if del < 0 { del = 0; }
        if del > len - start { del = len - start; }
    }
    i32 n_items = argc > 2 ? argc - 2 : 0;

    i32 rm = gc_root_mark(&vm.heap);
    JsObject* removed = js_new_array(&vm.heap, vm.array_proto);
    gc_root(&vm.heap, value_cell(&removed.head));
    for i32 i = 0; i < del; i++ {
        js_array_set(removed, i, al_get(vm, recv, start + i));
        if vm.has_pending { gc_root_reset(&vm.heap, rm); return value_undefined(); }
    }
    if n_items < del {
        for i32 i = start; i < len - del; i++ {
            al_set(vm, recv, i + n_items, al_get(vm, recv, i + del));
        }
        for i32 i = len - del + n_items; i < len; i++ { al_del(vm, recv, i); }
    } else if n_items > del {
        for i32 i = len - del - 1; i >= start; i-- {
            al_set(vm, recv, i + n_items, al_get(vm, recv, i + del));
        }
    }
    for i32 i = 0; i < n_items; i++ {
        al_set(vm, recv, start + i, *(args + 2 + i));
    }
    al_set_length(vm, recv, len - del + n_items);
    gc_root_reset(&vm.heap, rm);
    if vm.has_pending { return value_undefined(); }
    return value_cell(&removed.head);
}

private Value nat_arr_push(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    if needs_generic_array(thisv) { return arr_push_generic(vm, thisv, args, argc); }
    JsObject* a = this_array(vm, thisv);
    if a == null { return value_undefined(); }
    for i32 i = 0; i < argc; i++ {
        js_array_set(a, a.elen, *(args + i));
    }
    return value_int(a.elen);
}

private Value nat_arr_pop(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    if needs_generic_array(thisv) { return arr_pop_generic(vm, thisv); }
    JsObject* a = this_array(vm, thisv);
    if a == null { return value_undefined(); }
    if a.elen == 0 { return value_undefined(); }
    Value v = js_array_get(a, a.elen - 1);
    a.elen--;
    return v;
}

private Value nat_arr_shift(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    if needs_generic_array(thisv) { return arr_shift_generic(vm, thisv); }
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
    if needs_generic_array(thisv) { return arr_unshift_generic(vm, thisv, args, argc); }
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
    i32 target = rel_index(argc > 0 ? to_int_sat(*(args)) : 0, len);
    i32 start = rel_index(argc > 1 ? to_int_sat(*(args + 1)) : 0, len);
    i32 end = len;
    if argc > 2 && !value_is_undefined(*(args + 2)) {
        end = rel_index(to_int_sat(*(args + 2)), len);
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
    JsObject* a = this_arraylike(vm, thisv);
    if a == null { return value_undefined(); }
    i32 start = rel_index(argc > 0 ? to_int_sat(*(args)) : 0, a.elen);
    i32 end = a.elen;
    if argc > 1 && !value_is_undefined(*(args + 1)) {
        end = rel_index(to_int_sat(*(args + 1)), a.elen);
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
    if needs_generic_array(thisv) { return arr_splice_generic(vm, thisv, args, argc); }
    JsObject* a = this_array(vm, thisv);
    if a == null { return value_undefined(); }
    i32 start = rel_index(argc > 0 ? to_int_sat(*(args)) : 0, a.elen);
    i32 del = a.elen - start;
    if argc > 1 {
        del = to_int_sat(*(args + 1));
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
    // concat does not spread a non-array `this` (IsConcatSpreadable), so it
    // keeps the strict receiver rather than materializing an array-like.
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
    JsObject* a = this_arraylike(vm, thisv);
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
    JsObject* a = this_arraylike(vm, thisv);
    if a == null { return value_undefined(); }
    Value needle = arg_at(args, argc, 0);
    i32 start_at = argc > 1 ? rel_index(to_int_sat(*(args + 1)), a.elen) : 0;
    for i32 i = start_at; i < a.elen; i++ {
        if !js_array_has(a, i) { continue; }   // indexOf skips holes
        if js_strict_eq(js_array_get(a, i), needle) { return value_int(i); }
    }
    return value_int(-1);
}

private Value nat_arr_includes(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    JsObject* a = this_arraylike(vm, thisv);
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
    JsObject* a = this_arraylike(vm, thisv);
    if a == null { return value_undefined(); }
    Value needle = arg_at(args, argc, 0);
    i32 start = a.elen - 1;
    if argc > 1 && !value_is_undefined(*(args + 1)) {
        i32 s = to_int_sat(*(args + 1));
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
    JsObject* a = this_arraylike(vm, thisv);
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
    JsObject* a = this_arraylike(vm, thisv);
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
    JsObject* a = this_arraylike(vm, thisv);
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
    JsObject* a = this_arraylike(vm, thisv);
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
    JsObject* a = this_arraylike(vm, thisv);
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
    JsObject* a = this_arraylike(vm, thisv);
    if a == null { return value_undefined(); }
    i32 i = to_int_arg(arg_at(args, argc, 0));
    if i < 0 { i += a.elen; }
    if i < 0 || i >= a.elen { return value_undefined(); }
    return js_array_get(a, i);
}

private Value nat_arr_findlast(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    JsObject* a = this_arraylike(vm, thisv);
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
    JsObject* a = this_arraylike(vm, thisv);
    if a == null { return value_undefined(); }
    i32 depth = argc > 0 && !value_is_undefined(*(args)) ? to_int_sat(*(args)) : 1;
    JsObject* out = js_new_array(&vm.heap, vm.array_proto);
    i32 rm = gc_root_mark(&vm.heap);
    gc_root(&vm.heap, value_cell(&out.head));
    flatten_into(vm, a, out, depth);
    gc_root_reset(&vm.heap, rm);
    return value_cell(&out.head);
}

private Value nat_arr_flatmap(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    JsObject* a = this_arraylike(vm, thisv);
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
    if needs_generic_array(thisv) { return arr_reverse_generic(vm, thisv); }
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
    if needs_generic_array(thisv) { return arr_fill_generic(vm, thisv, args, argc); }
    JsObject* a = this_array(vm, thisv);
    if a == null { return value_undefined(); }
    Value v = arg_at(args, argc, 0);
    i32 start = argc > 1 ? rel_index(to_int_sat(*(args + 1)), a.elen) : 0;
    i32 end = argc > 2 ? rel_index(to_int_sat(*(args + 2)), a.elen) : a.elen;
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
    JsObject* a = this_arraylike(vm, thisv);
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

// Internal slot for a primitive-wrapper object's boxed value
// ([[NumberData]] / [[BooleanData]] / [[StringData]]). The '%' prefix
// keeps it out of enumeration and reflection.
private void set_wrapped_prim(VM* vm, JsObject* o, Value p) {
    props_set_desc(&o.props, bi_atom(vm, "%prim"), p, 0);
}

// If v is a wrapper object carrying a boxed primitive, returns it via out.
private bool wrapped_prim(VM* vm, Value v, Value* out) {
    if !value_is_object(v) { return false; }
    Value* p = props_get(&value_as_object(v).props, bi_atom(vm, "%prim"));
    if p == null { return false; }
    *out = *p;
    return true;
}

// Numeric this for Number.prototype methods: the number itself, or a
// Number wrapper's boxed value. NaN for anything else (loose callers).
private f64 num_this(VM* vm, Value thisv) {
    if value_is_number(thisv) { return js_to_number(thisv); }
    Value p;
    if wrapped_prim(vm, thisv, &p) && value_is_number(p) { return js_to_number(p); }
    return js_to_number(thisv);
}

private Value nat_string_ctor(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    Value p;
    if argc == 0 {
        p = new_str(vm, "");
    } else if value_is_symbol(*(args)) {
        // String(sym) is the descriptive string; new String(sym) throws.
        if value_is_object(thisv) {
            vm_throw_error(vm, ERR_TYPE, "Cannot convert a Symbol value to a string");
            return value_undefined();
        }
        return vm_symbol_desc(vm, *(args));
    } else {
        p = js_to_string_value(vm, *(args));
    }
    if vm.has_pending { return value_undefined(); }
    // new String(x): box the primitive on the fresh instance.
    if value_is_object(thisv) {
        JsObject* o = value_as_object(thisv);
        set_wrapped_prim(vm, o, p);
        props_set_desc(&o.props, bi_atom(vm, "length"), value_int(value_as_string(p).u16len), 0);
        return thisv;
    }
    return p;
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
    i32 start = rel_index(argc > 0 ? to_int_sat(*(args)) : 0, ulen);
    i32 end = ulen;
    if argc > 1 && !value_is_undefined(*(args + 1)) {
        end = rel_index(to_int_sat(*(args + 1)), ulen);
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
    i32 a = argc > 0 ? to_int_sat(*(args)) : 0;
    i32 b = ulen;
    if argc > 1 && !value_is_undefined(*(args + 1)) {
        b = to_int_sat(*(args + 1));
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
    i32 start = argc > 0 ? to_int_sat(*(args)) : 0;
    if start < 0 {
        start = ulen + start;
        if start < 0 { start = 0; }
    }
    if start > ulen { start = ulen; }
    i32 len = ulen - start;
    if argc > 1 && !value_is_undefined(*(args + 1)) {
        len = to_int_sat(*(args + 1));
        if len < 0 { len = 0; }
    }
    // compare against the remaining count, not start+len, to avoid overflow
    if len > ulen - start { len = ulen - start; }
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
    VM* vm = as_vm(vmp);
    if value_is_string(thisv) { return thisv; }
    Value p;
    if wrapped_prim(vm, thisv, &p) && value_is_string(p) { return p; }
    vm_throw_error(vm, ERR_TYPE, "String.prototype.toString requires that 'this' be a String");
    return value_undefined();
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
    return value_bool(own_prop_exists(vm, arg_at(args, argc, 0), arg_at(args, argc, 1)));
}

// --- Number / Boolean ------------------------------------------------------------

private Value nat_number_ctor(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    Value p;
    if argc == 0 {
        p = value_int(0);
    } else {
        Value x = *(args);
        if value_is_bigint(x) { p = js_number_value(bn_to_f64(bigint_view(value_as_bigint(x)))); }
        else { p = js_number_value(vm_to_number(vm, x)); }
    }
    if vm.has_pending { return value_undefined(); }
    if value_is_object(thisv) { set_wrapped_prim(vm, value_as_object(thisv), p); return thisv; }
    return p;
}

private Value nat_boolean_ctor(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    Value p = value_bool(js_truthy(arg_at(args, argc, 0)));
    if value_is_object(thisv) { set_wrapped_prim(vm, value_as_object(thisv), p); return thisv; }
    return p;
}

private Value nat_bool_valueof(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    if value_is_bool(thisv) { return thisv; }
    Value p;
    if wrapped_prim(vm, thisv, &p) && value_is_bool(p) { return p; }
    vm_throw_error(vm, ERR_TYPE, "Boolean.prototype.valueOf requires that 'this' be a Boolean");
    return value_undefined();
}

private Value nat_bool_tostring(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    Value b = thisv;
    if !value_is_bool(thisv) {
        Value p;
        if wrapped_prim(vm, thisv, &p) && value_is_bool(p) { b = p; }
        else {
            vm_throw_error(vm, ERR_TYPE, "Boolean.prototype.toString requires that 'this' be a Boolean");
            return value_undefined();
        }
    }
    return new_str(vm, value_is_true(b) ? "true" : "false");
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

// The legacy `escape` / `unescape` globals. They operate on UTF-16 code
// units; this iterates code points, which agrees with Node across the BMP
// (astral scalars still emit a surrogate pair, per spec). Common today only
// via `unescape(encodeURIComponent(s))` for UTF-8 byte strings.
private bool escape_unmodified(u32 cp) {
    if (cp >= 'A' && cp <= 'Z') || (cp >= 'a' && cp <= 'z') || (cp >= '0' && cp <= '9') { return true; }
    return cp == '@' || cp == '*' || cp == '_' || cp == '+' || cp == '-' || cp == '.' || cp == '/';
}

private void escape_put_u(str_buf* sb, str hex, u32 v16) {
    u8[6] esc;
    esc[0] = '%';
    esc[1] = 'u';
    esc[2] = *(hex.data + ((v16 >> 12) & 15));
    esc[3] = *(hex.data + ((v16 >> 8) & 15));
    esc[4] = *(hex.data + ((v16 >> 4) & 15));
    esc[5] = *(hex.data + (v16 & 15));
    str e;
    e.data = &esc[0];
    e.len = 6;
    str_buf_add(sb, e);
}

private Value nat_escape(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    i32 rm = gc_root_mark(&vm.heap);
    Value sv = js_to_string_value(vm, arg_at(args, argc, 0));
    gc_root(&vm.heap, sv);
    str s = sview(sv);
    str_buf sb;
    str_buf_init(&sb);
    str hex = "0123456789ABCDEF";
    i32 off = 0;
    while off < s.len {
        i32 n;
        u32 cp = cast(u32, utf8_decode(s, off, &n));
        off += n;
        if escape_unmodified(cp) {
            u8[1] ch;
            ch[0] = cast(u8, cp);
            str one;
            one.data = &ch[0];
            one.len = 1;
            str_buf_add(&sb, one);
        } else if cp < cast(u32, 256) {
            u8[3] esc;
            esc[0] = '%';
            esc[1] = *(hex.data + (cp >> 4));
            esc[2] = *(hex.data + (cp & 15));
            str e;
            e.data = &esc[0];
            e.len = 3;
            str_buf_add(&sb, e);
        } else if cp < cast(u32, 65536) {
            escape_put_u(&sb, hex, cp);
        } else {
            u32 v = cp - cast(u32, 65536);
            escape_put_u(&sb, hex, cast(u32, 0xD800) + (v >> 10));
            escape_put_u(&sb, hex, cast(u32, 0xDC00) + (v & cast(u32, 0x3FF)));
        }
    }
    Value r = new_str(vm, str_buf_to_str(&sb));
    str_buf_free(&sb);
    gc_root_reset(&vm.heap, rm);
    return r;
}

private Value nat_unescape(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    i32 rm = gc_root_mark(&vm.heap);
    Value sv = js_to_string_value(vm, arg_at(args, argc, 0));
    gc_root(&vm.heap, sv);
    str s = sview(sv);
    str_buf sb;
    str_buf_init(&sb);
    i32 i = 0;
    while i < s.len {
        u8 c = *(s.data + i);
        if c == '%' && i + 5 < s.len && *(s.data + i + 1) == 'u'
           && hex_val(*(s.data + i + 2)) >= 0 && hex_val(*(s.data + i + 3)) >= 0
           && hex_val(*(s.data + i + 4)) >= 0 && hex_val(*(s.data + i + 5)) >= 0 {
            i32 cp = (hex_val(*(s.data + i + 2)) << 12) | (hex_val(*(s.data + i + 3)) << 8)
                   | (hex_val(*(s.data + i + 4)) << 4) | hex_val(*(s.data + i + 5));
            i += 6;
            // a high surrogate immediately followed by a low surrogate escape
            // is one astral code point (the UTF-16 pair the code units form)
            if cp >= 0xD800 && cp <= 0xDBFF && i + 5 < s.len && *(s.data + i) == '%'
               && *(s.data + i + 1) == 'u'
               && hex_val(*(s.data + i + 2)) >= 0 && hex_val(*(s.data + i + 3)) >= 0
               && hex_val(*(s.data + i + 4)) >= 0 && hex_val(*(s.data + i + 5)) >= 0 {
                i32 lo = (hex_val(*(s.data + i + 2)) << 12) | (hex_val(*(s.data + i + 3)) << 8)
                       | (hex_val(*(s.data + i + 4)) << 4) | hex_val(*(s.data + i + 5));
                if lo >= 0xDC00 && lo <= 0xDFFF {
                    cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                    i += 6;
                }
            }
            wtf8_put_cp(&sb, cp);
        } else if c == '%' && i + 2 < s.len
                  && hex_val(*(s.data + i + 1)) >= 0 && hex_val(*(s.data + i + 2)) >= 0 {
            wtf8_put_cp(&sb, (hex_val(*(s.data + i + 1)) << 4) | hex_val(*(s.data + i + 2)));
            i += 3;
        } else {
            u8[1] ch;
            ch[0] = c;
            str one;
            one.data = &ch[0];
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
    f64 v = num_this(vm, thisv);
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
    f64 nval = num_this(vm, thisv);
    i32 radix = argc > 0 && !value_is_undefined(*(args)) ? to_int_arg(*(args)) : 10;
    if radix == 10 {
        return js_to_string_value(vm, js_number_value(nval));
    }
    if radix < 2 || radix > 36 {
        vm_throw_error(vm, ERR_RANGE, "radix must be between 2 and 36");
        return value_undefined();
    }
    // integer part only for non-decimal radixes
    f64 v = nval;
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
    VM* vm = as_vm(vmp);
    if value_is_number(thisv) { return thisv; }
    Value p;
    if wrapped_prim(vm, thisv, &p) && value_is_number(p) { return p; }
    vm_throw_error(vm, ERR_TYPE, "Number.prototype.valueOf requires that 'this' be a Number");
    return value_undefined();
}

private Value nat_num_toexponential(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    f64 v = num_this(vm, thisv);
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
    f64 v = num_this(vm, thisv);
    if value_is_undefined(pv) { return js_to_string_value(vm, js_number_value(v)); }
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
    f64 v = num_this(vm, thisv);
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
    // a proxy wrapping an array serializes as an array, reading its length and
    // elements through the traps
    bool proxied_array = (o.obj_flags & OBJF_ARRAY) == 0
        && (o.obj_flags & OBJF_PROXY) != 0 && is_array_pierced(v);
    if (o.obj_flags & OBJF_ARRAY) != 0 || proxied_array {
        i32 n = proxied_array ? al_length(vm, v) : o.elen;
        str_buf_add(sb, "[");
        for i32 i = 0; i < n; i++ {
            if i > 0 { str_buf_add(sb, ","); }
            json_indent_into(sb, gap, depth + 1);
            i32 rm = gc_root_mark(&vm.heap);
            string ks = format("{}", i);
            Value ev = proxied_array ? al_get(vm, v, i) : js_array_get(o, i);
            Value child = json_transform(vm, ctx, v, ks, ev);
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
        if n > 0 { json_indent_into(sb, gap, depth); }
        str_buf_add(sb, "]");
    } else if (o.obj_flags & OBJF_TYPEDARRAY) != 0 {
        // a typed array serializes like an object keyed by its indices
        str_buf_add(sb, "{");
        i32 len = ta_len(vm, o);
        bool first = true;
        for i32 i = 0; i < len; i++ {
            i32 rm = gc_root_mark(&vm.heap);
            string ks = format("{}", i);
            u32 key = atom_intern(&vm.atoms, ks);
            free(ks);
            Value cval = json_transform(vm, ctx, v, atom_name(&vm.atoms, key), vm_ta_get(vm, o, i));
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
                if vm.has_pending { ignore vec_pop(seen); return false; }
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
    } else {
        str_buf_add(sb, "{");
        bool first = true;
        // a proxy enumerates via its ownKeys + get traps, not its own props
        i32 pkrm = gc_root_mark(&vm.heap);
        JsObject* pkeys = null;
        if (o.obj_flags & OBJF_PROXY) != 0 && ctx.allow == null {
            pkeys = vm_own_keys(vm, v);
            gc_root(&vm.heap, value_cell(&pkeys.head));
        }
        // array replacer restricts (and orders) keys; otherwise own order
        i32 count = ctx.allow != null ? ctx.allow.len : (pkeys != null ? pkeys.elen : o.props.len);
        for i32 i = 0; i < count; i++ {
            u32 key = 0;
            if ctx.allow != null {
                key = vec_get(ctx.allow, i);
            } else if pkeys != null {
                key = atom_intern(&vm.atoms, sview(js_array_get(pkeys, i)));
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
        gc_root_reset(&vm.heap, pkrm);
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

// ES InternalizeJSONProperty: revive children bottom-up, then call
// reviver.call(holder, key, val). `val` is already fetched from holder.
private Value json_revive(VM* vm, Value holder, Value keyv, Value val, Value reviver) {
    i32 rm = gc_root_mark(&vm.heap);
    gc_root(&vm.heap, holder);
    gc_root(&vm.heap, keyv);
    gc_root(&vm.heap, val);
    if value_is_array(val) {
        JsObject* arr = value_as_object(val);
        for i32 i = 0; i < arr.elen; i++ {
            string is = format("{}", i);
            Value ikey = new_str(vm, is);
            free(is);
            vm_push(vm, ikey);
            Value nv = json_revive(vm, val, ikey, js_array_get(arr, i), reviver);
            if value_is_undefined(nv) { js_array_set(arr, i, value_hole()); }
            else { js_array_set(arr, i, nv); }
            vm_pop(vm);
        }
    } else if value_is_object(val) {
        JsObject* keys = vm_own_keys(vm, val);
        vm_push(vm, value_cell(&keys.head));
        i32 n = keys.elen;
        for i32 i = 0; i < n; i++ {
            Value kv = js_array_get(keys, i);
            vm_push(vm, kv);
            u32 ka = atom_intern(&vm.atoms, sview(kv));
            Value child;
            ignore vm_get_prop_value(vm, val, ka, &child);
            Value nv = json_revive(vm, val, kv, child, reviver);
            if value_is_undefined(nv) { ignore js_delete_prop(value_as_object(val), ka); }
            else { js_set_prop(value_as_object(val), ka, nv); }
            vm_pop(vm);
        }
        vm_pop(vm);
    }
    Value[2] ca = { keyv, val };
    Value result = vm_call_value(vm, reviver, holder, &ca[0], 2);
    gc_root_reset(&vm.heap, rm);
    return result;
}

// Parses JSON `text` to a Value; sets *ok. For internal callers (require
// of a .json file, package.json). No reviver.
Value builtins_json_parse(VM* vm, str text, bool* ok) {
    i32 rm = gc_root_mark(&vm.heap);
    JsonParser p;
    p.s = text;
    p.pos = 0;
    p.failed = false;
    Value r = json_parse_value(vm, &p);
    gc_root(&vm.heap, r);
    json_ws(&p);
    *ok = !p.failed && p.pos == p.s.len;
    gc_root_reset(&vm.heap, rm);
    if !*ok { return value_undefined(); }
    return r;
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
    // optional reviver: walk the result under a { "": r } holder
    Value reviver = arg_at(args, argc, 1);
    if value_is_callable(reviver) {
        JsObject* root = js_new_object(&vm.heap, vm.object_proto);
        vm_push(vm, value_cell(&root.head));
        js_set_prop(root, bi_atom(vm, ""), r);
        r = json_revive(vm, value_cell(&root.head), new_str(vm, ""), r, reviver);
        vm_pop(vm);
    }
    gc_root_reset(&vm.heap, rm);
    return r;
}

// --- Function.prototype ------------------------------------------------------------------

// The Function constructor compiles source at runtime; the interpreter
// does not support dynamic code. The global exists so that references to
// `Function` and `Function.prototype` resolve (only calling it throws).
private Value nat_function_ctor(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    vm_throw_error(as_vm(vmp), ERR_TYPE, "Function constructor (dynamic code) is not supported");
    return value_undefined();
}

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
    // apply(thisArg) with no list -> call with zero args
    if value_is_undefined(arr) || value_is_null(arr) {
        return vm_call_value(vm, thisv, this_arg, args, 0);
    }
    // any array-like list works (a real array, the arguments object, ...);
    // this_arraylike returns a real array directly or materializes one
    JsObject* a = this_arraylike(vm, arr);
    if a == null { return value_undefined(); }   // not array-like: it threw
    i32 rm = gc_root_mark(&vm.heap);
    gc_root(&vm.heap, value_cell(&a.head));
    Value r = vm_call_value(vm, thisv, this_arg, a.elems, a.elen);
    gc_root_reset(&vm.heap, rm);
    return r;
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
    str msg = "";
    bool has_msg = false;
    if !value_is_undefined(mv) {
        Value ms = js_to_string_value(vm, mv);
        gc_root(&vm.heap, ms);
        js_set_prop(target, vm.atom_message, ms);
        msg = sview(ms);
        has_msg = true;
    }
    // options.cause -> error.cause (own property of the options object)
    Value optv = arg_at(args, argc, 1);
    if value_is_object(optv) {
        Prop* ce = props_entry(&value_as_object(optv).props, bi_atom(vm, "cause"));
        if ce != null { js_set_prop(target, bi_atom(vm, "cause"), ce.val); }
    }
    // .stack, using the error's resolved name
    Value namev = value_undefined();
    ignore vm_get_prop_value(vm, value_cell(&target.head), vm.atom_name, &namev);
    str nm = "Error";
    if value_is_string(namev) { nm = sview(namev); }
    Value stack = vm_error_stack(vm, nm, msg, has_msg);
    js_set_prop(target, bi_atom(vm, "stack"), stack);
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
private Value nat_evalerror_ctor(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    return error_ctor_impl(as_vm(vmp), thisv, args, argc, ERR_EVAL);
}
private Value nat_urierror_ctor(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    return error_ctor_impl(as_vm(vmp), thisv, args, argc, ERR_URI);
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

// BigInt(x): from a BigInt (passthrough), integer Number, boolean, or
// decimal string.
private Value nat_bigint_ctor(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    Value x = arg_at(args, argc, 0);
    if value_is_bigint(x) { return x; }
    bool ok = true;
    BigNum bn;
    if value_is_bool(x) {
        bn = bn_from_i64(value_is_true(x) ? 1 : 0);
    } else if value_is_number(x) {
        f64 d = js_to_number(x);
        f64 inf = 1.0e308 * 10.0;
        if d != d || d == inf || d == -inf || d != floor(d) {
            vm_throw_error(vm, ERR_RANGE, "The number is not a safe integer");
            return value_undefined();
        }
        bn = bn_from_i64(cast(i64, d));
    } else if value_is_string(x) {
        str s = sview(x);
        // an empty (or all-blank) string is 0n
        bn = bn_from_str(s, &ok);
        if !ok {
            i32 a = 0;
            while a < s.len && (*(s.data + a) == ' ' || *(s.data + a) == '\t') { a++; }
            if a >= s.len { bn = bn_from_i64(0); ok = true; }
        }
        if !ok {
            vm_throw_error(vm, ERR_SYNTAX, "Cannot convert string to a BigInt");
            return value_undefined();
        }
    } else {
        vm_throw_error(vm, ERR_TYPE, "Cannot convert value to a BigInt");
        return value_undefined();
    }
    GcBigInt* g = js_new_bigint(&vm.heap, bn);
    bn_free(&bn);
    return value_cell(&g.head);
}

private Value nat_bigint_tostring(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    if !value_is_bigint(thisv) { return new_str(vm, "0"); }
    string s = bn_to_str(bigint_view(value_as_bigint(thisv)));
    Value r = new_str(vm, s);
    free(s);
    return r;
}

private Value nat_bigint_valueof(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    return thisv;
}

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

// Symbol.for(key): the shared registered symbol for `key` (stringified),
// created on first use so Symbol.for(k) === Symbol.for(k).
private Value nat_symbol_for(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    Value kv = js_to_string_value(vm, arg_at(args, argc, 0));
    if vm.symbol_registry == null {
        vm.symbol_registry = js_new_object(&vm.heap, null);
    }
    i32 rm = gc_root_mark(&vm.heap);
    gc_root(&vm.heap, kv);
    u32 a = atom_intern(&vm.atoms, sview(kv));
    Value existing;
    if js_get_prop(vm.symbol_registry, a, &existing) {
        gc_root_reset(&vm.heap, rm);
        return existing;
    }
    Value sym = vm_new_symbol(vm, kv);
    gc_root(&vm.heap, sym);
    js_set_prop(vm.symbol_registry, a, sym);
    gc_root_reset(&vm.heap, rm);
    return sym;
}

// Symbol.keyFor(sym): the registry key if `sym` came from Symbol.for, else
// undefined. Reverse-scans the registry by symbol identity.
private Value nat_symbol_key_for(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    Value sv = arg_at(args, argc, 0);
    if !value_is_symbol(sv) {
        vm_throw_error(vm, ERR_TYPE, "Symbol.keyFor requires a symbol argument");
        return value_undefined();
    }
    if vm.symbol_registry == null { return value_undefined(); }
    u32 id = value_as_symbol(sv).id;
    JsObject* reg = vm.symbol_registry;
    for i32 i = 0; i < reg.props.len; i++ {
        Value pv = (reg.props.items + i).val;
        if value_is_symbol(pv) && value_as_symbol(pv).id == id {
            return value_as_symbol(sv).desc;   // desc holds the registry key
        }
    }
    return value_undefined();
}

// --- array / string iterators ------------------------------------------------------

// The interned decimal-string key for a small array index.
private u32 index_atom(VM* vm, i32 i) {
    u8[16] buf;
    i32 n = 0;
    if i <= 0 {
        buf[0] = cast(u8, 48);   // '0'
        n = 1;
    } else {
        i32 v = i;
        while v > 0 { buf[n] = cast(u8, 48 + v % 10); n++; v = v / 10; }
        i32 a = 0;
        i32 b = n - 1;
        while a < b { u8 t = buf[a]; buf[a] = buf[b]; buf[b] = t; a++; b--; }
    }
    str s;
    s.data = &buf[0];
    s.len = n;
    return atom_intern(&vm.atoms, s);
}

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
    else if value_is_object(src) {
        // generic array-like (e.g. the arguments object): read `length`
        Value lv;
        if vm_get_prop_value(vm, src, vm.atom_length, &lv) { len = cast(i32, js_to_number(lv)); }
    }
    if i >= len {
        js_set_prop(r, vm_atom(vm, "done"), value_bool(true));
        js_set_prop(r, vm_atom(vm, "value"), value_undefined());
    } else {
        me.env1 = value_int(i + 1);
        i32 kind = value_is_int(me.env2) ? value_as_int(me.env2) : 0;
        Value elem;
        if value_is_array(src) {
            elem = js_array_get(value_as_object(src), i);
        } else if value_is_string(src) {
            // strings iterate by code point; `i` is a byte offset
            str view = gc_string_view(value_as_string(src));
            i32 n;
            ignore utf8_decode(view, i, &n);
            me.env1 = value_int(i + n);
            str one;
            one.data = view.data + i;
            one.len = n;
            elem = new_str(vm, one);
        } else {
            // generic array-like: read the i-th indexed property (env1 already i+1)
            Value ev;
            elem = vm_get_prop_value(vm, src, index_atom(vm, i), &ev) ? ev : value_undefined();
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

// Build the `arguments` object: an array-like plain object (Object.prototype
// proto, so not an Array and without Array methods) with own enumerable
// indices, a non-enumerable `length`, and a values iterator. Unmapped — a
// snapshot of the argument values. Installed as the VM's ArgumentsBuilder.
Value build_arguments_object(VM* vm, Value* argstart, i32 argc) {
    i32 rm = gc_root_mark(&vm.heap);
    JsObject* o = js_new_object(&vm.heap, vm.object_proto);
    gc_root(&vm.heap, value_cell(&o.head));
    for i32 i = 0; i < argc; i++ {
        js_set_prop(o, index_atom(vm, i), *(argstart + i));
    }
    props_set_desc(&o.props, vm.atom_length, value_int(argc),
        PROP_WRITABLE | PROP_CONFIGURABLE);   // length: own, non-enumerable
    JsNative* si = js_new_native(&vm.heap, &nat_arr_symiter, "[Symbol.iterator]");
    props_set_desc(&o.props, vm_sym_iterator_id(vm), value_cell(&si.head), METHOD_ATTRS);
    gc_root_reset(&vm.heap, rm);
    return value_cell(&o.head);
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

// Promise.allSettled: never rejects; each element records
// { status, value|reason } and the result fulfills when all settle.
private Value settled_record(VM* vm, Value callee, Value* args, i32 argc, bool fulfilled) {
    JsNative* me = value_as_native(callee);
    JsObject* st = value_as_object(me.env0);
    i32 idx = value_as_int(me.env1);
    i32 rm = gc_root_mark(&vm.heap);
    JsObject* rec = js_new_object(&vm.heap, vm.object_proto);
    gc_root(&vm.heap, value_cell(&rec.head));
    if fulfilled {
        js_set_prop(rec, vm_atom(vm, "status"), new_str(vm, "fulfilled"));
        js_set_prop(rec, vm_atom(vm, "value"), arg_at(args, argc, 0));
    } else {
        js_set_prop(rec, vm_atom(vm, "status"), new_str(vm, "rejected"));
        js_set_prop(rec, vm_atom(vm, "reason"), arg_at(args, argc, 0));
    }
    Value resultsv;
    ignore js_get_prop(st, vm_atom(vm, "results"), &resultsv);
    js_array_set(value_as_object(resultsv), idx, value_cell(&rec.head));
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
private Value nat_settled_ful(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    return settled_record(as_vm(vmp), callee, args, argc, true);
}
private Value nat_settled_rej(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    return settled_record(as_vm(vmp), callee, args, argc, false);
}

// Rejects a Promise.any with an AggregateError over the collected reasons.
private void any_reject_all(VM* vm, Value pv, Value errsv) {
    i32 rm = gc_root_mark(&vm.heap);
    gc_root(&vm.heap, pv);
    gc_root(&vm.heap, errsv);
    JsObject* agg = js_new_object(&vm.heap, vm.error_protos[ERR_ERROR]);
    gc_root(&vm.heap, value_cell(&agg.head));
    js_set_prop(agg, vm.atom_name, new_str(vm, "AggregateError"));
    js_set_prop(agg, vm.atom_message, new_str(vm, "All promises were rejected"));
    js_set_prop(agg, vm_atom(vm, "errors"), errsv);
    vm_promise_settle(vm, pv, value_cell(&agg.head), true);
    gc_root_reset(&vm.heap, rm);
}

private Value nat_any_ful(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    JsNative* me = value_as_native(callee);
    JsObject* st = value_as_object(me.env0);
    Value pv;
    ignore js_get_prop(st, vm_atom(vm, "promise"), &pv);
    i32 rm = gc_root_mark(&vm.heap);
    gc_root(&vm.heap, pv);
    Value a = arg_at(args, argc, 0);
    gc_root(&vm.heap, a);
    vm_promise_settle(vm, pv, a, false);   // first fulfillment wins (idempotent)
    gc_root_reset(&vm.heap, rm);
    return value_undefined();
}
private Value nat_any_rej(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    JsNative* me = value_as_native(callee);
    JsObject* st = value_as_object(me.env0);
    i32 idx = value_as_int(me.env1);
    i32 rm = gc_root_mark(&vm.heap);
    Value errsv;
    ignore js_get_prop(st, vm_atom(vm, "results"), &errsv);
    js_array_set(value_as_object(errsv), idx, arg_at(args, argc, 0));
    Value remv;
    ignore js_get_prop(st, vm_atom(vm, "remaining"), &remv);
    i32 rem = value_as_int(remv) - 1;
    js_set_prop(st, vm_atom(vm, "remaining"), value_int(rem));
    if rem == 0 {
        Value pv;
        ignore js_get_prop(st, vm_atom(vm, "promise"), &pv);
        any_reject_all(vm, pv, errsv);
    }
    gc_root_reset(&vm.heap, rm);
    return value_undefined();
}

// Shared setup for allSettled/any: a state object over an array input,
// wiring each element's promise to the given fulfill/reject natives.
// `any` inverts the empty/settle semantics via `is_any`.
private Value promise_combine(VM* vm, Value list, NativeFn onful, NativeFn onrej, bool is_any) {
    if !value_is_array(list) {
        vm_throw_error(vm, ERR_TYPE, "Promise combinator expects an array");
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
        if is_any { any_reject_all(vm, p, value_cell(&results.head)); }
        else { vm_promise_settle(vm, p, value_cell(&results.head), false); }
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
        JsNative* onf = js_new_native(&vm.heap, onful, "combine");
        onf.env0 = value_cell(&st.head);
        onf.env1 = value_int(i);
        vm_push(vm, value_cell(&onf.head));
        JsNative* onr = js_new_native(&vm.heap, onrej, "combine");
        onr.env0 = value_cell(&st.head);
        onr.env1 = value_int(i);
        Value onfv = vm_pop_ret(vm, value_cell(&onf.head));
        ignore vm_promise_then(vm, evp, onfv, value_cell(&onr.head));
        vm_pop(vm);
    }
    gc_root_reset(&vm.heap, rm);
    return p;
}

private Value nat_promise_allsettled(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    return promise_combine(as_vm(vmp), arg_at(args, argc, 0), &nat_settled_ful, &nat_settled_rej, false);
}
private Value nat_promise_any(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    return promise_combine(as_vm(vmp), arg_at(args, argc, 0), &nat_any_ful, &nat_any_rej, true);
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

// WeakMap/WeakSet: keys are held weakly and must be references (objects,
// functions, arrays). No iteration or size — keys are not observable.
private Value make_weak(VM* vm, Value iterable, bool is_set) {
    JsObject* proto = is_set ? vm_weakset_proto(vm) : vm_weakmap_proto(vm);
    JsMap* mp = js_new_map(&vm.heap, proto, is_set);
    mp.weak = true;
    if bi_nullish(iterable) { return value_cell(&mp.head); }
    i32 rm = gc_root_mark(&vm.heap);
    gc_root(&vm.heap, value_cell(&mp.head));
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
                if !value_is_reference(e) {
                    vm_throw_error(vm, ERR_TYPE, "Invalid value used in weak set");
                    break;
                }
                map_put(mp, e, value_undefined());
            } else if value_is_array(e) {
                JsObject* pair = value_as_object(e);
                Value k = js_array_get(pair, 0);
                if !value_is_reference(k) {
                    vm_throw_error(vm, ERR_TYPE, "Invalid value used as weak map key");
                    break;
                }
                map_put(mp, k, js_array_get(pair, 1));
            }
        }
    }
    gc_root_reset(&vm.heap, rm);
    if vm.has_pending { return value_undefined(); }
    return value_cell(&mp.head);
}

private Value nat_weakmap_ctor(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    return make_weak(as_vm(vmp), arg_at(args, argc, 0), false);
}
private Value nat_weakset_ctor(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    return make_weak(as_vm(vmp), arg_at(args, argc, 0), true);
}

private Value nat_weakmap_set(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    JsMap* mp = this_map(vm, thisv);
    if mp == null { return value_undefined(); }
    Value k = arg_at(args, argc, 0);
    if !value_is_reference(k) {
        vm_throw_error(vm, ERR_TYPE, "Invalid value used as weak map key");
        return value_undefined();
    }
    map_put(mp, k, arg_at(args, argc, 1));
    return thisv;
}
private Value nat_weakset_add(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    JsMap* mp = this_map(vm, thisv);
    if mp == null { return value_undefined(); }
    Value k = arg_at(args, argc, 0);
    if !value_is_reference(k) {
        vm_throw_error(vm, ERR_TYPE, "Invalid value used in weak set");
        return value_undefined();
    }
    map_put(mp, k, value_undefined());
    return thisv;
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

private str wday_abbr(i32 w) {
    if w == 0 { return "Sun"; }
    if w == 1 { return "Mon"; }
    if w == 2 { return "Tue"; }
    if w == 3 { return "Wed"; }
    if w == 4 { return "Thu"; }
    if w == 5 { return "Fri"; }
    return "Sat";
}

private str month_abbr(i32 m) {
    if m == 0 { return "Jan"; }
    if m == 1 { return "Feb"; }
    if m == 2 { return "Mar"; }
    if m == 3 { return "Apr"; }
    if m == 4 { return "May"; }
    if m == 5 { return "Jun"; }
    if m == 6 { return "Jul"; }
    if m == 7 { return "Aug"; }
    if m == 8 { return "Sep"; }
    if m == 9 { return "Oct"; }
    if m == 10 { return "Nov"; }
    return "Dec";
}

// Reads exactly `count` decimal digits at *i into *out; false if fewer.
private bool ds_digits(str s, i32* i, i32 count, i32* out) {
    i32 v = 0;
    for i32 k = 0; k < count; k++ {
        if *i >= s.len { return false; }
        u8 c = *(s.data + *i);
        if c < '0' || c > '9' { return false; }
        v = v * 10 + cast(i32, c - '0');
        *i = *i + 1;
    }
    *out = v;
    return true;
}

// Parses ISO 8601: YYYY[-MM[-DD]][(T| )HH:mm[:ss[.sss]]][Z|±hh[:]mm].
// A date-only string and one with a trailing Z are UTC; a time without an
// offset is also treated as UTC (the interpreter has no local zone).
// Returns NaN when the whole string is not consumed or a field is invalid.
private f64 date_parse_iso(str s) {
    f64 nan = 0.0 / 0.0;
    i32 i = 0;
    i32 end = s.len;
    while i < end && *(s.data + i) == ' ' { i++; }
    while end > i && *(s.data + end - 1) == ' ' { end--; }
    i32 year = 0;
    if !ds_digits(s, &i, 4, &year) { return nan; }
    i32 month = 1;
    i32 day = 1;
    i32 hour = 0;
    i32 min = 0;
    i32 sec = 0;
    i32 ms = 0;
    i32 off_min = 0;
    if i < end && *(s.data + i) == '-' {
        i++;
        if !ds_digits(s, &i, 2, &month) { return nan; }
        if i < end && *(s.data + i) == '-' {
            i++;
            if !ds_digits(s, &i, 2, &day) { return nan; }
        }
    }
    if i < end && (*(s.data + i) == 'T' || *(s.data + i) == ' ') {
        i++;
        if !ds_digits(s, &i, 2, &hour) { return nan; }
        if i >= end || *(s.data + i) != ':' { return nan; }
        i++;
        if !ds_digits(s, &i, 2, &min) { return nan; }
        if i < end && *(s.data + i) == ':' {
            i++;
            if !ds_digits(s, &i, 2, &sec) { return nan; }
            if i < end && *(s.data + i) == '.' {
                i++;
                i32 frac = 0;
                i32 fc = 0;
                while i < end && fc < 3 && *(s.data + i) >= '0' && *(s.data + i) <= '9' {
                    frac = frac * 10 + cast(i32, *(s.data + i) - '0');
                    fc++;
                    i++;
                }
                while fc < 3 { frac = frac * 10; fc++; }
                while i < end && *(s.data + i) >= '0' && *(s.data + i) <= '9' { i++; }
                ms = frac;
            }
        }
        if i < end {
            u8 c = *(s.data + i);
            if c == 'Z' {
                i++;
            } else if c == '+' || c == '-' {
                bool neg = c == '-';
                i++;
                i32 oh = 0;
                i32 om = 0;
                if !ds_digits(s, &i, 2, &oh) { return nan; }
                if i < end && *(s.data + i) == ':' { i++; }
                if !ds_digits(s, &i, 2, &om) { return nan; }
                off_min = oh * 60 + om;
                if neg { off_min = -off_min; }
            }
        }
    }
    if i != end { return nan; }
    if month < 1 || month > 12 || day < 1 || day > 31 { return nan; }
    if hour > 24 || min > 59 || sec > 59 { return nan; }
    f64 t = date_compose(cast(i64, year), month - 1, day, hour, min, sec, ms);
    return t - cast(f64, off_min) * 60000.0;   // local field time -> UTC
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
        // new Date(string) parses; new Date(number|Date) is a time value
        if value_is_string(*(args)) { t = date_parse_iso(sview(*(args))); }
        else { t = js_to_number(*(args)); }
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

private Value nat_date_parse(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    Value a0 = arg_at(args, argc, 0);
    if !value_is_string(a0) { return value_number(0.0 / 0.0); }
    return value_number(date_parse_iso(sview(a0)));
}

// Appends a 4+-digit year (zero-padded to 4 like the ISO/toString forms).
private void date_fmt_year(str_buf* sb, i64 y) {
    if y < 0 { str_buf_add(sb, "-"); y = -y; }
    if y < 1000 { str_buf_add(sb, "0"); }
    if y < 100 { str_buf_add(sb, "0"); }
    if y < 10 { str_buf_add(sb, "0"); }
    string ys = format("{}", y);
    str_buf_add(sb, ys);
    free(ys);
}

// "Thu Jan 01 1970"
private void date_fmt_datepart(str_buf* sb, DateParts d) {
    str_buf_add(sb, wday_abbr(d.wday));
    str_buf_add(sb, " ");
    str_buf_add(sb, month_abbr(d.month));
    str_buf_add(sb, " ");
    pad2(sb, d.day);
    str_buf_add(sb, " ");
    date_fmt_year(sb, d.year);
}

// "00:00:00 GMT+0000 (Coordinated Universal Time)"
private void date_fmt_timepart(str_buf* sb, DateParts d) {
    pad2(sb, d.hour);
    str_buf_add(sb, ":");
    pad2(sb, d.min);
    str_buf_add(sb, ":");
    pad2(sb, d.sec);
    str_buf_add(sb, " GMT+0000 (Coordinated Universal Time)");
}

// Shared entry for the toString family. mode: 0 full, 1 date, 2 time,
// 3 UTC (RFC 7231), 4 locale-date, 5 locale-time, 6 locale full.
private Value date_string(VM* vm, Value thisv, i32 mode) {
    f64 t = date_ms(vm, thisv);
    if t != t { return new_str(vm, "Invalid Date"); }
    DateParts d = date_decompose(t);
    str_buf sb;
    str_buf_init(&sb);
    if mode == 0 {
        date_fmt_datepart(&sb, d);
        str_buf_add(&sb, " ");
        date_fmt_timepart(&sb, d);
    } else if mode == 1 {
        date_fmt_datepart(&sb, d);
    } else if mode == 2 {
        date_fmt_timepart(&sb, d);
    } else if mode == 3 {
        str_buf_add(&sb, wday_abbr(d.wday));
        str_buf_add(&sb, ", ");
        pad2(&sb, d.day);
        str_buf_add(&sb, " ");
        str_buf_add(&sb, month_abbr(d.month));
        str_buf_add(&sb, " ");
        date_fmt_year(&sb, d.year);
        str_buf_add(&sb, " ");
        pad2(&sb, d.hour);
        str_buf_add(&sb, ":");
        pad2(&sb, d.min);
        str_buf_add(&sb, ":");
        pad2(&sb, d.sec);
        str_buf_add(&sb, " GMT");
    } else {
        // locale forms: en-US numeric, e.g. "1/1/1970", "12:00:00 AM"
        bool want_date = mode == 4 || mode == 6;
        bool want_time = mode == 5 || mode == 6;
        if want_date {
            string ds = format("{}/{}/{}", d.month + 1, d.day, d.year);
            str_buf_add(&sb, ds);
            free(ds);
        }
        if want_date && want_time { str_buf_add(&sb, ", "); }
        if want_time {
            i32 h12 = d.hour % 12;
            if h12 == 0 { h12 = 12; }
            string hs = format("{}", h12);
            str_buf_add(&sb, hs);
            free(hs);
            str_buf_add(&sb, ":");
            pad2(&sb, d.min);
            str_buf_add(&sb, ":");
            pad2(&sb, d.sec);
            str_buf_add(&sb, d.hour < 12 ? " AM" : " PM");
        }
    }
    Value r = new_str(vm, str_buf_to_str(&sb));
    str_buf_free(&sb);
    return r;
}

private Value nat_date_tostring(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    return date_string(as_vm(vmp), thisv, 0);
}
private Value nat_date_todatestring(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    return date_string(as_vm(vmp), thisv, 1);
}
private Value nat_date_totimestring(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    return date_string(as_vm(vmp), thisv, 2);
}
private Value nat_date_toutcstring(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    return date_string(as_vm(vmp), thisv, 3);
}
private Value nat_date_tolocaledate(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    return date_string(as_vm(vmp), thisv, 4);
}
private Value nat_date_tolocaletime(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    return date_string(as_vm(vmp), thisv, 5);
}
private Value nat_date_tolocalestring(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    return date_string(as_vm(vmp), thisv, 6);
}

// Date.prototype[Symbol.toPrimitive]: a "number" hint takes valueOf (the
// timestamp), while "string" and "default" take toString — so `date +
// date` concatenates strings rather than adding timestamps.
private Value nat_date_toprimitive(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    Value hint = arg_at(args, argc, 0);
    bool number = value_is_string(hint) && str_equal(sview(hint), "number");
    u32 key = number ? bi_atom(vm, "valueOf") : bi_atom(vm, "toString");
    Value m;
    if !vm_get_prop_value(vm, thisv, key, &m) { return value_undefined(); }
    if !value_is_callable(m) {
        vm_throw_error(vm, ERR_TYPE, "Date coercion method is not callable");
        return value_undefined();
    }
    Value dummy = value_undefined();
    return vm_call_value(vm, m, thisv, &dummy, 0);
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

// Installs the entry file's __filename / __dirname as global bindings.
// These are entry-scoped, not per-module: imported modules see the entry
// file's paths (documented in doc/PLAN_M16_node_globals.md). Set after
// builtins_install, so they are not part of the globalThis snapshot,
// matching Node (where they are module-local, not globalThis properties).
void builtins_set_entry(VM* vm, str filename, str dirname) {
    vm_set_global(vm, "__filename", new_str(vm, filename));
    vm_set_global(vm, "__dirname", new_str(vm, dirname));
}

// Constants (e.g. Math.PI): non-writable, non-enumerable, non-configurable.
private void def_value(VM* vm, JsObject* obj, str name, Value v) {
    props_set_desc(&obj.props, bi_atom(vm, name), v, 0);
}

// Numeric constant on a constructor (e.g. Number.MAX_VALUE): same frozen
// attributes as def_value, but the props live on a JsNative ctor.
private void num_const(VM* vm, JsNative* ctor, str name, f64 v) {
    props_set_desc(&ctor.props, bi_atom(vm, name), value_number(v), 0);
}

// Links a prototype back to its constructor (proto.constructor = ctor).
private void link_ctor(VM* vm, JsObject* proto, JsNative* ctor) {
    props_set_desc(&proto.props, bi_atom(vm, "constructor"), value_cell(&ctor.head), METHOD_ATTRS);
}

// Installs a getter-only accessor property (non-enumerable, configurable).
private void def_accessor(VM* vm, JsObject* obj, str name, NativeFn getter) {
    JsNative* g = js_new_native(&vm.heap, getter, name);
    // keep the getter alive across the accessor allocation, which can GC
    vm_push(vm, value_cell(&g.head));
    JsAccessor* ac = js_new_accessor(&vm.heap);
    ac.get = value_cell(&g.head);
    props_set_desc(&obj.props, bi_atom(vm, name), value_cell(&ac.head), PROP_CONFIGURABLE);
    vm_pop(vm);
}

// --- process ----------------------------------------------------------------
//
// A Node-like `process` global. OS facilities (pid, cwd, environment,
// monotonic clock) are reached through platform externs behind `when`.

struct ProcTimespec { i64 tv_sec; i64 tv_nsec; }

// Enumerable data property (the normal writable/enumerable/configurable
// shape), as opposed to def_value's frozen constants.
private void def_value_enum(VM* vm, JsObject* obj, str name, Value v) {
    props_set_desc(&obj.props, bi_atom(vm, name), v, PROP_DEFAULT);
}

// Splits a "NAME=VALUE" entry and adds it to the env object. `env` must be
// reachable (rooted) already; new_str is the only collecting allocation.
private void env_add(VM* vm, JsObject* env, str entry) {
    if entry.len == 0 { return; }
    // Windows exposes drive-cwd pseudo-vars like "=C:=..."; skip them.
    if *(entry.data) == '=' { return; }
    i32 eq = -1;
    for i32 i = 0; i < entry.len; i++ {
        if *(entry.data + i) == '=' { eq = i; break; }
    }
    if eq < 0 { return; }
    str name;
    name.data = entry.data;
    name.len = eq;
    str val;
    val.data = entry.data + eq + 1;
    val.len = entry.len - eq - 1;
    u32 key = atom_intern(&vm.atoms, name);
    Value vs = new_str(vm, val);
    props_set_desc(&env.props, key, vs, PROP_DEFAULT);
}

when os(windows) {
    private str os_platform_name() { return "win32"; }
    private extern "kernel32.dll" u32 GetCurrentProcessId();
    private extern "kernel32.dll" u32 GetCurrentDirectoryA(u32 len, u8* buf);
    private extern "kernel32.dll" u8* GetEnvironmentStringsA();
    private extern "kernel32.dll" i32 FreeEnvironmentStringsA(u8* p);
    private extern "kernel32.dll" i32 QueryPerformanceCounter(i64* p);
    private extern "kernel32.dll" i32 QueryPerformanceFrequency(i64* p);
    private extern "msvcrt.dll" i32 _isatty(i32 fd);

    private bool os_isatty(i32 fd) { return _isatty(fd) != 0; }
    private i32 os_pid() { return cast(i32, GetCurrentProcessId()); }

    private Value os_cwd_str(VM* vm) {
        u8[4096] buf;
        u32 n = GetCurrentDirectoryA(4096, &buf[0]);
        str s;
        s.data = &buf[0];
        s.len = cast(i32, n);
        return new_str(vm, s);
    }

    private u64 os_mono_ns() {
        i64 freq = 0;
        i64 ctr = 0;
        ignore QueryPerformanceFrequency(&freq);
        ignore QueryPerformanceCounter(&ctr);
        if freq == 0 { return 0; }
        u64 uc = cast(u64, ctr);
        u64 uf = cast(u64, freq);
        // split to avoid overflow: ns = secs*1e9 + rem*1e9/freq
        u64 secs = uc / uf;
        u64 rem = uc % uf;
        return secs * 1000000000 + rem * 1000000000 / uf;
    }

    private void os_env_install(VM* vm, JsObject* env) {
        u8* block = GetEnvironmentStringsA();
        if block == null { return; }
        u8* p = block;
        while *p != 0 {
            u8* start = p;
            while *p != 0 { p++; }
            // Windows env is case-insensitive; Node exposes it that way.
            // Uppercase the NAME (ASCII) in the owned block so the common
            // `process.env.PATH` lookup resolves the stored "Path" key.
            for u8* q = start; q < p && *q != '='; q++ {
                u8 ch = *q;
                if ch >= 'a' && ch <= 'z' { *q = cast(u8, ch - 32); }
            }
            str entry;
            entry.data = start;
            entry.len = cast(i32, p - start);
            env_add(vm, env, entry);
            p++;
        }
        ignore FreeEnvironmentStringsA(block);
    }
}
else when os(wasm) {
    // Sandbox: no process identity, no cwd, no environment. The
    // monotonic counter is the host clock import (qpf is 1e9 there).
    private str os_platform_name() { return "wasm"; }
    private bool os_isatty(i32 fd) { return false; }
    private i32 os_pid() { return 0; }
    private Value os_cwd_str(VM* vm) { return new_str(vm, "/"); }
    private u64 os_mono_ns() { return cast(u64, qpc()); }
    private void os_env_install(VM* vm, JsObject* env) { }
}
else when os(macos) || os(ios) || os(linux) || os(android) {
    when os(macos) || os(ios) {
        private str os_platform_name() { return "darwin"; }
        private extern "libSystem.B.dylib" i32 getpid();
        private extern "libSystem.B.dylib" u8* getcwd(u8* buf, u64 size);
        private extern "libSystem.B.dylib" i32 clock_gettime(i32 clk, ProcTimespec* ts);
        private extern "libSystem.B.dylib" u8*** _NSGetEnviron();
        private extern "libSystem.B.dylib" i32 isatty(i32 fd);
        private u8** os_environ() { return *_NSGetEnviron(); }
        private i32 os_mono_clock() { return 6; }  // CLOCK_MONOTONIC (darwin)
    }
    else when os(android) {
        private str os_platform_name() { return "android"; }
        private extern "libc.so" i32 getpid();
        private extern "libc.so" u8* getcwd(u8* buf, u64 size);
        private extern "libc.so" i32 clock_gettime(i32 clk, ProcTimespec* ts);
        private extern "libc.so" u8** environ;
        private extern "libc.so" i32 isatty(i32 fd);
        private u8** os_environ() { return environ; }
        private i32 os_mono_clock() { return 1; }  // CLOCK_MONOTONIC (linux)
    }
    else {
        private str os_platform_name() { return "linux"; }
        private extern "libc.so.6" i32 getpid();
        private extern "libc.so.6" u8* getcwd(u8* buf, u64 size);
        private extern "libc.so.6" i32 clock_gettime(i32 clk, ProcTimespec* ts);
        private extern "libc.so.6" u8** environ;
        private extern "libc.so.6" i32 isatty(i32 fd);
        private u8** os_environ() { return environ; }
        private i32 os_mono_clock() { return 1; }  // CLOCK_MONOTONIC (linux)
    }

    private bool os_isatty(i32 fd) { return isatty(fd) != 0; }
    private i32 os_pid() { return getpid(); }

    private Value os_cwd_str(VM* vm) {
        u8[4096] buf;
        u8* r = getcwd(&buf[0], 4096);
        if r == null { return new_str(vm, ""); }
        return new_str(vm, str_from_cstr(&buf[0]));
    }

    private u64 os_mono_ns() {
        ProcTimespec ts;
        ts.tv_sec = 0;
        ts.tv_nsec = 0;
        ignore clock_gettime(os_mono_clock(), &ts);
        return cast(u64, ts.tv_sec) * 1000000000 + cast(u64, ts.tv_nsec);
    }

    private void os_env_install(VM* vm, JsObject* env) {
        u8** e = os_environ();
        if e == null { return; }
        while *e != null {
            env_add(vm, env, str_from_cstr(*e));
            e++;
        }
    }
}
else {
    // No arm for this target. Add a `when os(...)` arm above rather
    // than letting it fall back to another platform's syscalls.
    tsmc_unsupported_target__add_a_when_os_arm _unsupported_proc;
}

when arch(arm64) { private str os_arch_name() { return "arm64"; } }
else when arch(wasm32) { private str os_arch_name() { return "wasm32"; } }
else { private str os_arch_name() { return "x64"; } }

// Writes a string verbatim (no trailing newline) to stdout or stderr,
// substituting U+FFFD for lone surrogates the UTF-8 sink can't take.
private void proc_raw_write(VM* vm, Value sv, bool to_err) {
    str view = sview(sv);
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
}

private Value nat_process_stdout_write(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    Value s = js_to_string_value(vm, arg_at(args, argc, 0));
    vm_push(vm, s);
    proc_raw_write(vm, s, false);
    vm_pop(vm);
    return value_bool(true);
}

private Value nat_process_stderr_write(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    Value s = js_to_string_value(vm, arg_at(args, argc, 0));
    vm_push(vm, s);
    proc_raw_write(vm, s, true);
    vm_pop(vm);
    return value_bool(true);
}

private Value nat_process_cwd(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    return os_cwd_str(as_vm(vmp));
}

private Value nat_process_exit(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    i32 code = 0;
    Value c = arg_at(args, argc, 0);
    if !value_is_undefined(c) { code = to_int_arg(c); }
    exit(code);
    return value_undefined();
}

private Value nat_process_next_tick(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    Value cb = arg_at(args, argc, 0);
    if !value_is_callable(cb) {
        vm_throw_error(vm, ERR_TYPE, "callback is not a function");
        return value_undefined();
    }
    Value scheduled = cb;
    i32 rm = gc_root_mark(&vm.heap);
    if argc > 1 {
        // bind the extra args: cb.bind(undefined, ...rest)
        Value* ba = alloc<Value>(argc);
        *(ba) = value_undefined();
        for i32 i = 1; i < argc; i++ { *(ba + i) = *(args + i); }
        scheduled = nat_fn_bind(vmp, value_undefined(), cb, ba, argc);
        free(ba);
    }
    gc_root(&vm.heap, scheduled);
    // schedule via an already-resolved promise reaction
    Value p = vm_promise_new(vm);
    gc_root(&vm.heap, p);
    vm_promise_settle(vm, p, value_undefined(), false);
    ignore vm_promise_then(vm, p, scheduled, value_undefined());
    gc_root_reset(&vm.heap, rm);
    return value_undefined();
}

private Value nat_process_hrtime(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    u64 now = os_mono_ns();
    u64 prev_total = 0;
    Value pv = arg_at(args, argc, 0);
    if value_is_array(pv) {
        JsObject* pa = value_as_object(pv);
        u64 ps = cast(u64, cast(i64, js_to_number(js_array_get(pa, 0))));
        u64 pn = cast(u64, cast(i64, js_to_number(js_array_get(pa, 1))));
        prev_total = ps * 1000000000 + pn;
    }
    u64 diff = now - prev_total;
    JsObject* arr = js_new_array(&vm.heap, vm.array_proto);
    vm_push(vm, value_cell(&arr.head));
    js_array_set(arr, 0, value_number(cast(f64, diff / 1000000000)));
    js_array_set(arr, 1, value_number(cast(f64, diff % 1000000000)));
    vm_pop(vm);
    return value_cell(&arr.head);
}

private Value nat_process_hrtime_bigint(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    u64 now = os_mono_ns();
    BigNum bn = bn_from_i64(cast(i64, now));
    GcBigInt* g = js_new_bigint(&vm.heap, bn);
    bn_free(&bn);
    return value_cell(&g.head);
}

private void process_install(VM* vm) {
    JsObject* proc = js_new_object(&vm.heap, vm.object_proto);
    // set as a global first so it is a GC root while we build its children
    vm_set_global(vm, "process", value_cell(&proc.head));

    // argv: [execPath, script, ...userArgs], mirroring Node's shape.
    JsObject* argv = js_new_array(&vm.heap, vm.array_proto);
    def_value_enum(vm, proc, "argv", value_cell(&argv.head));
    i32 ac = get_argc();
    js_array_set(argv, 0, new_str(vm, str_from_cstr(get_arg(0))));
    i32 src = 1;
    // skip interpreter flags (only --gc-stress can reach a running script)
    while src < ac {
        str a = str_from_cstr(get_arg(src));
        if a.len >= 2 && *(a.data) == '-' && *(a.data + 1) == '-' { src++; continue; }
        break;
    }
    i32 dst = 1;
    while src < ac {
        js_array_set(argv, dst, new_str(vm, str_from_cstr(get_arg(src))));
        dst++;
        src++;
    }
    def_value_enum(vm, proc, "argv0", new_str(vm, str_from_cstr(get_arg(0))));

    // env: a snapshot object of the real environment.
    JsObject* env = js_new_object(&vm.heap, vm.object_proto);
    def_value_enum(vm, proc, "env", value_cell(&env.head));
    os_env_install(vm, env);

    def_value_enum(vm, proc, "platform", new_str(vm, os_platform_name()));
    def_value_enum(vm, proc, "arch", new_str(vm, os_arch_name()));
    def_value_enum(vm, proc, "pid", value_number(cast(f64, os_pid())));
    def_value_enum(vm, proc, "version", new_str(vm, "v22.0.0"));

    JsObject* vers = js_new_object(&vm.heap, vm.object_proto);
    def_value_enum(vm, proc, "versions", value_cell(&vers.head));
    def_value_enum(vm, vers, "node", new_str(vm, "22.0.0"));
    def_value_enum(vm, vers, "tsmc", new_str(vm, "0.1.0-dev"));

    // isTTY is present (true) only for a real terminal, matching Node,
    // which leaves it undefined when the stream is piped or redirected.
    JsObject* out = js_new_object(&vm.heap, vm.object_proto);
    def_value_enum(vm, proc, "stdout", value_cell(&out.head));
    def_method(vm, out, "write", &nat_process_stdout_write);
    if os_isatty(1) { def_value_enum(vm, out, "isTTY", value_bool(true)); }

    JsObject* errobj = js_new_object(&vm.heap, vm.object_proto);
    def_value_enum(vm, proc, "stderr", value_cell(&errobj.head));
    def_method(vm, errobj, "write", &nat_process_stderr_write);
    if os_isatty(2) { def_value_enum(vm, errobj, "isTTY", value_bool(true)); }

    def_method(vm, proc, "cwd", &nat_process_cwd);
    def_method(vm, proc, "exit", &nat_process_exit);
    def_method(vm, proc, "nextTick", &nat_process_next_tick);

    // hrtime(prev?) -> [s, ns]; hrtime.bigint() -> nanoseconds
    JsNative* hr = js_new_native(&vm.heap, &nat_process_hrtime, "hrtime");
    props_set_desc(&proc.props, bi_atom(vm, "hrtime"), value_cell(&hr.head), PROP_DEFAULT);
    JsNative* hrb = js_new_native(&vm.heap, &nat_process_hrtime_bigint, "bigint");
    props_set_desc(&hr.props, bi_atom(vm, "bigint"), value_cell(&hrb.head), PROP_DEFAULT);
}

// --- Buffer -----------------------------------------------------------------
//
// Node's Buffer, backed by a JS array of byte values (0-255) whose prototype
// chains through Buffer.prototype to Array.prototype. This reuses array
// indexing, `.length`, and iteration for free; the Buffer methods (decode,
// encode, numeric reads/writes) live on Buffer.prototype. Each byte is one
// Value, favoring reuse over a packed store.

const i32 ENC_UTF8 = 0;
const i32 ENC_HEX = 1;
const i32 ENC_BASE64 = 2;
const i32 ENC_BASE64URL = 3;
const i32 ENC_LATIN1 = 4;
const i32 ENC_ASCII = 5;

private bool ci_eq(str a, str b) {
    if a.len != b.len { return false; }
    for i32 i = 0; i < a.len; i++ {
        u8 ca = *(a.data + i);
        u8 cb = *(b.data + i);
        if ca >= 'A' && ca <= 'Z' { ca = cast(u8, ca + 32); }
        if cb >= 'A' && cb <= 'Z' { cb = cast(u8, cb + 32); }
        if ca != cb { return false; }
    }
    return true;
}

private i32 buf_parse_enc(Value v, i32 dflt) {
    if !value_is_string(v) { return dflt; }
    str s = sview(v);
    if ci_eq(s, "utf8") || ci_eq(s, "utf-8") { return ENC_UTF8; }
    if ci_eq(s, "hex") { return ENC_HEX; }
    if ci_eq(s, "base64") { return ENC_BASE64; }
    if ci_eq(s, "base64url") { return ENC_BASE64URL; }
    if ci_eq(s, "latin1") || ci_eq(s, "binary") { return ENC_LATIN1; }
    if ci_eq(s, "ascii") { return ENC_ASCII; }
    return dflt;
}

// Byte 0-255 at index i (0 for holes / out of range).
private i32 buf_byte(JsObject* o, i32 i) {
    Value v = js_array_get(o, i);
    if !value_is_number(v) { return 0; }
    return cast(i32, cast(i64, js_to_number(v))) & 0xFF;
}

private JsObject* buf_new(VM* vm, i32 len) {
    JsObject* b = js_new_array(&vm.heap, vm.buffer_proto);
    for i32 i = 0; i < len; i++ {
        js_array_set(b, i, value_number(0.0));
    }
    return b;
}

private Value buf_from_bytes(VM* vm, u8* data, i32 len) {
    JsObject* b = buf_new(vm, len);
    for i32 i = 0; i < len; i++ {
        js_array_set(b, i, value_number(cast(f64, *(data + i))));
    }
    return value_cell(&b.head);
}

private bool is_buffer(VM* vm, Value v) {
    if !value_is_object(v) { return false; }
    JsObject* o = value_as_object(v);
    return (o.obj_flags & OBJF_ARRAY) != 0 && o.proto == vm.buffer_proto;
}

// Normalizes a possibly-negative index to [0, len].
private i32 buf_clamp(i32 i, i32 len) {
    if i < 0 { i = len + i; }
    if i < 0 { i = 0; }
    if i > len { i = len; }
    return i;
}

// --- base64 / hex codecs ---

private void b64_emit(str_buf* sb, str alpha, u8 c62, u8 c63, i32 v) {
    if v == 62 { str_buf_add_byte(sb, c62); }
    else if v == 63 { str_buf_add_byte(sb, c63); }
    else { str_buf_add_byte(sb, *(alpha.data + v)); }
}

private void b64_encode(str_buf* sb, JsObject* b, i32 start, i32 end, bool url) {
    str alpha = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    u8 c62 = cast(u8, url ? '-' : '+');
    u8 c63 = cast(u8, url ? '_' : '/');
    i32 i = start;
    while end - i >= 3 {
        i32 n = (buf_byte(b, i) << 16) | (buf_byte(b, i + 1) << 8) | buf_byte(b, i + 2);
        b64_emit(sb, alpha, c62, c63, (n >> 18) & 0x3F);
        b64_emit(sb, alpha, c62, c63, (n >> 12) & 0x3F);
        b64_emit(sb, alpha, c62, c63, (n >> 6) & 0x3F);
        b64_emit(sb, alpha, c62, c63, n & 0x3F);
        i += 3;
    }
    i32 rem = end - i;
    if rem == 1 {
        i32 n = buf_byte(b, i) << 16;
        b64_emit(sb, alpha, c62, c63, (n >> 18) & 0x3F);
        b64_emit(sb, alpha, c62, c63, (n >> 12) & 0x3F);
        if !url { str_buf_add_byte(sb, '='); str_buf_add_byte(sb, '='); }
    } else if rem == 2 {
        i32 n = (buf_byte(b, i) << 16) | (buf_byte(b, i + 1) << 8);
        b64_emit(sb, alpha, c62, c63, (n >> 18) & 0x3F);
        b64_emit(sb, alpha, c62, c63, (n >> 12) & 0x3F);
        b64_emit(sb, alpha, c62, c63, (n >> 6) & 0x3F);
        if !url { str_buf_add_byte(sb, '='); }
    }
}

private i32 b64_val(u8 c) {
    if c >= 'A' && c <= 'Z' { return c - 'A'; }
    if c >= 'a' && c <= 'z' { return c - 'a' + 26; }
    if c >= '0' && c <= '9' { return c - '0' + 52; }
    if c == '+' || c == '-' { return 62; }
    if c == '/' || c == '_' { return 63; }
    return -1;
}

private void b64_decode(str_buf* out, str s) {
    i32 acc = 0;
    i32 nbits = 0;
    for i32 i = 0; i < s.len; i++ {
        i32 v = b64_val(*(s.data + i));
        if v < 0 { continue; }
        acc = (acc << 6) | v;
        nbits += 6;
        if nbits >= 8 {
            nbits -= 8;
            str_buf_add_byte(out, cast(u8, (acc >> nbits) & 0xFF));
        }
    }
}

private void hex_decode(str_buf* out, str s) {
    i32 i = 0;
    while i + 1 < s.len {
        i32 hi = hex_val(*(s.data + i));
        i32 lo = hex_val(*(s.data + i + 1));
        if hi < 0 || lo < 0 { break; }
        str_buf_add_byte(out, cast(u8, (hi << 4) | lo));
        i += 2;
    }
    // an odd trailing char that is a hex digit still contributes nothing,
    // matching Node (it stops at the first byte it can't complete).
}

// Decodes a WTF-8 string to code points, pushing (cp & mask) per unit.
private void str_low_bytes(str_buf* out, str s, i32 mask) {
    i32 i = 0;
    while i < s.len {
        u8 c = *(s.data + i);
        i32 cp = c;
        i32 adv = 1;
        if c >= 0x80 {
            if (c & 0xE0) == 0xC0 {
                cp = ((c & 0x1F) << 6) | (*(s.data + i + 1) & 0x3F);
                adv = 2;
            } else if (c & 0xF0) == 0xE0 {
                cp = ((c & 0x0F) << 12) | ((*(s.data + i + 1) & 0x3F) << 6) | (*(s.data + i + 2) & 0x3F);
                adv = 3;
            } else {
                cp = ((c & 0x07) << 18) | ((*(s.data + i + 1) & 0x3F) << 12) | ((*(s.data + i + 2) & 0x3F) << 6) | (*(s.data + i + 3) & 0x3F);
                adv = 4;
            }
        }
        str_buf_add_byte(out, cast(u8, cp & mask));
        i += adv;
    }
}

// Encodes a JS string into raw bytes under the given encoding.
private void str_to_bytes(str_buf* out, str s, i32 enc) {
    if enc == ENC_UTF8 {
        str_buf_add_bytes(out, s.data, s.len);
    } else if enc == ENC_HEX {
        hex_decode(out, s);
    } else if enc == ENC_BASE64 || enc == ENC_BASE64URL {
        b64_decode(out, s);
    } else if enc == ENC_LATIN1 {
        str_low_bytes(out, s, 0xFF);
    } else if enc == ENC_ASCII {
        str_low_bytes(out, s, 0x7F);
    }
}

// Decodes buffer bytes [start,end) into a JS string under the encoding.
private Value bytes_to_str(VM* vm, JsObject* b, i32 enc, i32 start, i32 end) {
    str_buf sb;
    str_buf_init(&sb);
    if enc == ENC_UTF8 || enc == ENC_LATIN1 || enc == ENC_ASCII {
        for i32 i = start; i < end; i++ {
            i32 by = buf_byte(b, i);
            if enc == ENC_UTF8 {
                str_buf_add_byte(&sb, cast(u8, by));
            } else if enc == ENC_ASCII {
                u8[4] tmp;
                i32 n = bi_utf8_encode(&tmp[0], cast(u32, by & 0x7F));
                str_buf_add_bytes(&sb, &tmp[0], n);
            } else {
                u8[4] tmp;
                i32 n = bi_utf8_encode(&tmp[0], cast(u32, by));
                str_buf_add_bytes(&sb, &tmp[0], n);
            }
        }
    } else if enc == ENC_HEX {
        str alpha = "0123456789abcdef";
        for i32 i = start; i < end; i++ {
            i32 by = buf_byte(b, i);
            str_buf_add_byte(&sb, *(alpha.data + (by >> 4)));
            str_buf_add_byte(&sb, *(alpha.data + (by & 0xF)));
        }
    } else {
        b64_encode(&sb, b, start, end, enc == ENC_BASE64URL);
    }
    str r = str_buf_to_str(&sb);
    Value v = new_str(vm, r);
    str_buf_free(&sb);
    return v;
}

// --- Buffer statics ---

private Value nat_buffer_from(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    Value src = arg_at(args, argc, 0);
    if value_is_string(src) {
        i32 enc = buf_parse_enc(arg_at(args, argc, 1), ENC_UTF8);
        str_buf sb;
        str_buf_init(&sb);
        str_to_bytes(&sb, sview(src), enc);
        Value r = buf_from_bytes(vm, sb.data, sb.len);
        str_buf_free(&sb);
        return r;
    }
    if value_is_array(src) {
        JsObject* a = value_as_object(src);
        i32 n = a.elen;
        JsObject* b = buf_new(vm, n);
        for i32 i = 0; i < n; i++ {
            Value e = js_array_get(a, i);
            i32 by = value_is_number(e) ? (cast(i32, cast(i64, js_to_number(e))) & 0xFF) : 0;
            js_array_set(b, i, value_number(cast(f64, by)));
        }
        return value_cell(&b.head);
    }
    vm_throw_error(vm, ERR_TYPE, "Buffer.from expects a string or array");
    return value_undefined();
}

private Value nat_buffer_alloc(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    i32 size = to_int_arg(arg_at(args, argc, 0));
    if size < 0 { size = 0; }
    JsObject* b = buf_new(vm, size);
    Value fill = arg_at(args, argc, 1);
    if value_is_number(fill) {
        i32 by = cast(i32, cast(i64, js_to_number(fill))) & 0xFF;
        for i32 i = 0; i < size; i++ { js_array_set(b, i, value_number(cast(f64, by))); }
    } else if value_is_string(fill) {
        i32 enc = buf_parse_enc(arg_at(args, argc, 2), ENC_UTF8);
        str_buf sb;
        str_buf_init(&sb);
        str_to_bytes(&sb, sview(fill), enc);
        if sb.len > 0 {
            for i32 i = 0; i < size; i++ {
                js_array_set(b, i, value_number(cast(f64, *(sb.data + (i % sb.len)))));
            }
        }
        str_buf_free(&sb);
    }
    return value_cell(&b.head);
}

private Value nat_buffer_concat(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    Value list = arg_at(args, argc, 0);
    if !value_is_array(list) { return value_cell(&buf_new(vm, 0).head); }
    JsObject* la = value_as_object(list);
    i32 total = 0;
    for i32 i = 0; i < la.elen; i++ {
        Value bv = js_array_get(la, i);
        if value_is_array(bv) { total += value_as_object(bv).elen; }
    }
    Value tl = arg_at(args, argc, 1);
    i32 cap = value_is_number(tl) ? to_int_arg(tl) : total;
    if cap < 0 { cap = 0; }
    JsObject* out = buf_new(vm, cap);
    i32 pos = 0;
    for i32 i = 0; i < la.elen && pos < cap; i++ {
        Value bv = js_array_get(la, i);
        if value_is_array(bv) {
            JsObject* src = value_as_object(bv);
            for i32 j = 0; j < src.elen && pos < cap; j++ {
                js_array_set(out, pos, value_number(cast(f64, buf_byte(src, j))));
                pos++;
            }
        }
    }
    return value_cell(&out.head);
}

private Value nat_buffer_is_buffer(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    return value_bool(is_buffer(as_vm(vmp), arg_at(args, argc, 0)));
}

private Value nat_buffer_byte_length(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    Value v = arg_at(args, argc, 0);
    if is_buffer(vm, v) { return value_number(cast(f64, value_as_object(v).elen)); }
    if !value_is_string(v) { return value_number(0.0); }
    i32 enc = buf_parse_enc(arg_at(args, argc, 1), ENC_UTF8);
    str_buf sb;
    str_buf_init(&sb);
    str_to_bytes(&sb, sview(v), enc);
    i32 n = sb.len;
    str_buf_free(&sb);
    return value_number(cast(f64, n));
}

// --- Buffer methods ---

private Value nat_buf_to_string(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    if !value_is_object(thisv) { return new_str(vm, ""); }
    JsObject* b = value_as_object(thisv);
    i32 enc = buf_parse_enc(arg_at(args, argc, 0), ENC_UTF8);
    i32 len = b.elen;
    Value sv = arg_at(args, argc, 1);
    Value ev = arg_at(args, argc, 2);
    i32 start = value_is_undefined(sv) ? 0 : buf_clamp(to_int_arg(sv), len);
    i32 end = value_is_undefined(ev) ? len : buf_clamp(to_int_arg(ev), len);
    if start > end { start = end; }
    return bytes_to_str(vm, b, enc, start, end);
}

private Value nat_buf_slice(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    JsObject* b = value_as_object(thisv);
    i32 len = b.elen;
    Value sv = arg_at(args, argc, 0);
    Value ev = arg_at(args, argc, 1);
    i32 start = value_is_undefined(sv) ? 0 : buf_clamp(to_int_arg(sv), len);
    i32 end = value_is_undefined(ev) ? len : buf_clamp(to_int_arg(ev), len);
    i32 n = end - start;
    if n < 0 { n = 0; }
    JsObject* out = buf_new(vm, n);
    for i32 i = 0; i < n; i++ {
        js_array_set(out, i, value_number(cast(f64, buf_byte(b, start + i))));
    }
    return value_cell(&out.head);
}

private Value nat_buf_equals(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    Value ov = arg_at(args, argc, 0);
    if !value_is_object(thisv) || !value_is_array(ov) { return value_bool(false); }
    JsObject* a = value_as_object(thisv);
    JsObject* b = value_as_object(ov);
    if a.elen != b.elen { return value_bool(false); }
    for i32 i = 0; i < a.elen; i++ {
        if buf_byte(a, i) != buf_byte(b, i) { return value_bool(false); }
    }
    return value_bool(true);
}

private Value nat_buf_compare(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    JsObject* a = value_as_object(thisv);
    Value ov = arg_at(args, argc, 0);
    if !value_is_array(ov) { return value_number(0.0); }
    JsObject* b = value_as_object(ov);
    i32 n = a.elen < b.elen ? a.elen : b.elen;
    for i32 i = 0; i < n; i++ {
        i32 x = buf_byte(a, i);
        i32 y = buf_byte(b, i);
        if x < y { return value_number(-1.0); }
        if x > y { return value_number(1.0); }
    }
    if a.elen < b.elen { return value_number(-1.0); }
    if a.elen > b.elen { return value_number(1.0); }
    return value_number(0.0);
}

private Value nat_buf_copy(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    JsObject* src = value_as_object(thisv);
    Value tv = arg_at(args, argc, 0);
    if !value_is_array(tv) { return value_number(0.0); }
    JsObject* tgt = value_as_object(tv);
    i32 tstart = value_is_undefined(arg_at(args, argc, 1)) ? 0 : to_int_arg(arg_at(args, argc, 1));
    i32 sstart = value_is_undefined(arg_at(args, argc, 2)) ? 0 : to_int_arg(arg_at(args, argc, 2));
    i32 send = value_is_undefined(arg_at(args, argc, 3)) ? src.elen : to_int_arg(arg_at(args, argc, 3));
    if sstart < 0 { sstart = 0; }
    if send > src.elen { send = src.elen; }
    if tstart < 0 { tstart = 0; }
    i32 count = 0;
    i32 s = sstart;
    i32 t = tstart;
    while s < send && t < tgt.elen {
        js_array_set(tgt, t, value_number(cast(f64, buf_byte(src, s))));
        s++;
        t++;
        count++;
    }
    return value_number(cast(f64, count));
}

private Value nat_buf_fill(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    JsObject* b = value_as_object(thisv);
    i32 len = b.elen;
    Value fv = arg_at(args, argc, 0);
    Value sv = arg_at(args, argc, 1);
    Value ev = arg_at(args, argc, 2);
    i32 start = value_is_undefined(sv) ? 0 : buf_clamp(to_int_arg(sv), len);
    i32 end = value_is_undefined(ev) ? len : buf_clamp(to_int_arg(ev), len);
    if value_is_number(fv) {
        i32 by = cast(i32, cast(i64, js_to_number(fv))) & 0xFF;
        for i32 i = start; i < end; i++ { js_array_set(b, i, value_number(cast(f64, by))); }
    } else if value_is_string(fv) {
        i32 enc = buf_parse_enc(arg_at(args, argc, 3), ENC_UTF8);
        str_buf pb;
        str_buf_init(&pb);
        str_to_bytes(&pb, sview(fv), enc);
        if pb.len > 0 {
            for i32 i = start; i < end; i++ {
                js_array_set(b, i, value_number(cast(f64, *(pb.data + ((i - start) % pb.len)))));
            }
        }
        str_buf_free(&pb);
    }
    return thisv;
}

private Value nat_buf_write(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    JsObject* b = value_as_object(thisv);
    Value sv = arg_at(args, argc, 0);
    if !value_is_string(sv) { return value_number(0.0); }
    i32 offset = value_is_undefined(arg_at(args, argc, 1)) ? 0 : to_int_arg(arg_at(args, argc, 1));
    if offset < 0 { offset = 0; }
    i32 avail = b.elen - offset;
    if avail < 0 { avail = 0; }
    // write(str, offset, length, encoding) or write(str, offset, encoding)
    i32 maxlen = avail;
    i32 enc = ENC_UTF8;
    Value a2 = arg_at(args, argc, 2);
    Value a3 = arg_at(args, argc, 3);
    if value_is_number(a2) {
        maxlen = to_int_arg(a2);
        enc = buf_parse_enc(a3, ENC_UTF8);
    } else {
        enc = buf_parse_enc(a2, ENC_UTF8);
    }
    if maxlen > avail { maxlen = avail; }
    str_buf sb;
    str_buf_init(&sb);
    str_to_bytes(&sb, sview(sv), enc);
    i32 n = sb.len < maxlen ? sb.len : maxlen;
    for i32 i = 0; i < n; i++ {
        js_array_set(b, offset + i, value_number(cast(f64, *(sb.data + i))));
    }
    str_buf_free(&sb);
    return value_number(cast(f64, n));
}

// Byte position of a number or substring needle, or -1.
private i32 buf_find(VM* vm, JsObject* b, Value needle, i32 begin, i32 enc) {
    i32 len = b.elen;
    if begin < 0 { begin = len + begin; }
    if begin < 0 { begin = 0; }
    if value_is_number(needle) {
        i32 by = cast(i32, cast(i64, js_to_number(needle))) & 0xFF;
        for i32 i = begin; i < len; i++ {
            if buf_byte(b, i) == by { return i; }
        }
        return -1;
    }
    if !value_is_string(needle) { return -1; }
    str_buf sb;
    str_buf_init(&sb);
    str_to_bytes(&sb, sview(needle), enc);
    i32 nl = sb.len;
    i32 found = -1;
    if nl == 0 {
        found = begin <= len ? begin : len;
    } else {
        for i32 i = begin; i + nl <= len; i++ {
            bool ok = true;
            for i32 j = 0; j < nl; j++ {
                if buf_byte(b, i + j) != cast(i32, *(sb.data + j)) { ok = false; break; }
            }
            if ok { found = i; break; }
        }
    }
    str_buf_free(&sb);
    return found;
}

private Value nat_buf_index_of(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    JsObject* b = value_as_object(thisv);
    i32 begin = value_is_undefined(arg_at(args, argc, 1)) ? 0 : to_int_arg(arg_at(args, argc, 1));
    i32 enc = buf_parse_enc(arg_at(args, argc, 2), ENC_UTF8);
    return value_number(cast(f64, buf_find(vm, b, arg_at(args, argc, 0), begin, enc)));
}

private Value nat_buf_includes(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    JsObject* b = value_as_object(thisv);
    i32 begin = value_is_undefined(arg_at(args, argc, 1)) ? 0 : to_int_arg(arg_at(args, argc, 1));
    i32 enc = buf_parse_enc(arg_at(args, argc, 2), ENC_UTF8);
    return value_bool(buf_find(vm, b, arg_at(args, argc, 0), begin, enc) >= 0);
}

private Value nat_buf_to_json(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    JsObject* b = value_as_object(thisv);
    JsObject* obj = js_new_object(&vm.heap, vm.object_proto);
    vm_push(vm, value_cell(&obj.head));
    def_value_enum(vm, obj, "type", new_str(vm, "Buffer"));
    JsObject* data = js_new_array(&vm.heap, vm.array_proto);
    def_value_enum(vm, obj, "data", value_cell(&data.head));
    for i32 i = 0; i < b.elen; i++ {
        js_array_set(data, i, value_number(cast(f64, buf_byte(b, i))));
    }
    vm_pop(vm);
    return value_cell(&obj.head);
}

// --- numeric reads / writes ---

private Value nat_buf_read_u8(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    JsObject* b = value_as_object(thisv);
    i32 o = to_int_arg(arg_at(args, argc, 0));
    return value_number(cast(f64, buf_byte(b, o)));
}

private Value nat_buf_read_i8(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    JsObject* b = value_as_object(thisv);
    i32 o = to_int_arg(arg_at(args, argc, 0));
    i32 v = buf_byte(b, o);
    if v >= 128 { v -= 256; }
    return value_number(cast(f64, v));
}

private Value nat_buf_write_u8(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    JsObject* b = value_as_object(thisv);
    i32 v = to_int_arg(arg_at(args, argc, 0)) & 0xFF;
    i32 o = to_int_arg(arg_at(args, argc, 1));
    js_array_set(b, o, value_number(cast(f64, v)));
    return value_number(cast(f64, o + 1));
}

private Value nat_buf_read_u16le(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    JsObject* b = value_as_object(thisv);
    i32 o = to_int_arg(arg_at(args, argc, 0));
    return value_number(cast(f64, buf_byte(b, o) | (buf_byte(b, o + 1) << 8)));
}

private Value nat_buf_read_u16be(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    JsObject* b = value_as_object(thisv);
    i32 o = to_int_arg(arg_at(args, argc, 0));
    return value_number(cast(f64, (buf_byte(b, o) << 8) | buf_byte(b, o + 1)));
}

private Value nat_buf_write_u16le(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    JsObject* b = value_as_object(thisv);
    i32 v = to_int_arg(arg_at(args, argc, 0)) & 0xFFFF;
    i32 o = to_int_arg(arg_at(args, argc, 1));
    js_array_set(b, o, value_number(cast(f64, v & 0xFF)));
    js_array_set(b, o + 1, value_number(cast(f64, (v >> 8) & 0xFF)));
    return value_number(cast(f64, o + 2));
}

private Value nat_buf_write_u16be(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    JsObject* b = value_as_object(thisv);
    i32 v = to_int_arg(arg_at(args, argc, 0)) & 0xFFFF;
    i32 o = to_int_arg(arg_at(args, argc, 1));
    js_array_set(b, o, value_number(cast(f64, (v >> 8) & 0xFF)));
    js_array_set(b, o + 1, value_number(cast(f64, v & 0xFF)));
    return value_number(cast(f64, o + 2));
}

private Value nat_buf_read_u32le(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    JsObject* b = value_as_object(thisv);
    i32 o = to_int_arg(arg_at(args, argc, 0));
    i64 v = cast(i64, buf_byte(b, o)) | (cast(i64, buf_byte(b, o + 1)) << 8)
        | (cast(i64, buf_byte(b, o + 2)) << 16) | (cast(i64, buf_byte(b, o + 3)) << 24);
    return value_number(cast(f64, v));
}

private Value nat_buf_read_u32be(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    JsObject* b = value_as_object(thisv);
    i32 o = to_int_arg(arg_at(args, argc, 0));
    i64 v = (cast(i64, buf_byte(b, o)) << 24) | (cast(i64, buf_byte(b, o + 1)) << 16)
        | (cast(i64, buf_byte(b, o + 2)) << 8) | cast(i64, buf_byte(b, o + 3));
    return value_number(cast(f64, v));
}

private Value nat_buf_write_u32le(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    JsObject* b = value_as_object(thisv);
    i64 v = cast(i64, js_to_number(arg_at(args, argc, 0)));
    i32 o = to_int_arg(arg_at(args, argc, 1));
    js_array_set(b, o, value_number(cast(f64, v & 0xFF)));
    js_array_set(b, o + 1, value_number(cast(f64, (v >> 8) & 0xFF)));
    js_array_set(b, o + 2, value_number(cast(f64, (v >> 16) & 0xFF)));
    js_array_set(b, o + 3, value_number(cast(f64, (v >> 24) & 0xFF)));
    return value_number(cast(f64, o + 4));
}

private Value nat_buf_write_u32be(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    JsObject* b = value_as_object(thisv);
    i64 v = cast(i64, js_to_number(arg_at(args, argc, 0)));
    i32 o = to_int_arg(arg_at(args, argc, 1));
    js_array_set(b, o, value_number(cast(f64, (v >> 24) & 0xFF)));
    js_array_set(b, o + 1, value_number(cast(f64, (v >> 16) & 0xFF)));
    js_array_set(b, o + 2, value_number(cast(f64, (v >> 8) & 0xFF)));
    js_array_set(b, o + 3, value_number(cast(f64, v & 0xFF)));
    return value_number(cast(f64, o + 4));
}

private Value nat_buffer_ctor(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    Value a = arg_at(args, argc, 0);
    // Legacy new Buffer(...) forms: number -> alloc, string/array -> from.
    if value_is_number(a) {
        i32 size = cast(i32, cast(i64, js_to_number(a)));
        if size < 0 { size = 0; }
        return value_cell(&buf_new(vm, size).head);
    }
    return nat_buffer_from(vmp, callee, thisv, args, argc);
}

// --- ArrayBuffer / TypedArray / DataView ------------------------------------
//
// An ArrayBuffer owns a GcBytes cell (raw storage). Typed arrays and
// DataViews are views: they hold the same GcBytes in elems[0] (so the GC
// keeps it alive) plus hidden layout props (%taoff/%talen/%takind) and
// visible descriptor props (buffer/byteOffset/byteLength/length). Element
// access goes through vm_ta_get / vm_ta_set from the index opcodes.

private bool is_arraybuffer(VM* vm, Value v) {
    return value_is_object(v) && value_as_object(v).proto == vm.arraybuffer_proto;
}

private bool is_dataview(VM* vm, Value v) {
    return value_is_object(v) && value_as_object(v).proto == vm.dataview_proto;
}

private i32 ta_len(VM* vm, JsObject* o) {
    Value* p = props_get(&o.props, vm.atom_ta_len);
    return p == null ? 0 : value_as_int(*p);
}

private i32 ta_off(VM* vm, JsObject* o) {
    Value* p = props_get(&o.props, vm.atom_ta_off);
    return p == null ? 0 : value_as_int(*p);
}

private i32 ta_kind(VM* vm, JsObject* o) {
    Value* p = props_get(&o.props, vm.atom_ta_kind);
    return p == null ? 0 : value_as_int(*p);
}

private i32 ab_len(VM* vm, JsObject* ab) {
    return value_as_bytes(*(ab.elems)).len;
}

// Fetches the ArrayBuffer backing a view (stored in the hidden %tabuf prop;
// the public `buffer` property is a prototype getter over this).
private JsObject* ta_buffer(VM* vm, JsObject* o) {
    Value* p = props_get(&o.props, bi_atom(vm, "%tabuf"));
    return p == null ? null : value_as_object(*p);
}

// Allocates a fresh ArrayBuffer of nbytes zeroed bytes.
private JsObject* ab_new(VM* vm, i32 nbytes) {
    if nbytes < 0 { nbytes = 0; }
    JsObject* ab = js_new_object(&vm.heap, vm.arraybuffer_proto);
    vm_push(vm, value_cell(&ab.head));
    GcBytes* gb = js_new_bytes(&vm.heap, nbytes);
    vm_push(vm, value_cell(&gb.head));
    js_array_set(ab, 0, value_cell(&gb.head));   // elems[0] roots the bytes
    vm.sp -= 2;
    return ab;   // byteLength is a prototype getter over the bytes cell
}

// Builds a typed-array view of `kind` over `buffer` starting at byte
// offset `boff` with `len` elements. Shares the buffer's byte storage.
private Value ta_make(VM* vm, i32 kind, JsObject* buffer, i32 boff, i32 len) {
    i32 rm = gc_root_mark(&vm.heap);
    gc_root(&vm.heap, value_cell(&buffer.head));
    JsObject* ta = js_new_object(&vm.heap, vm.ta_protos[kind]);
    ta.obj_flags = ta.obj_flags | OBJF_TYPEDARRAY;
    gc_root(&vm.heap, value_cell(&ta.head));
    GcBytes* gb = value_as_bytes(*(buffer.elems));
    js_array_set(ta, 0, value_cell(&gb.head));
    // hidden layout; length/byteLength/byteOffset/buffer are prototype getters
    props_set_desc(&ta.props, vm.atom_ta_off, value_int(boff), 0);
    props_set_desc(&ta.props, vm.atom_ta_len, value_int(len), 0);
    props_set_desc(&ta.props, vm.atom_ta_kind, value_int(kind), 0);
    props_set_desc(&ta.props, bi_atom(vm, "%tabuf"), value_cell(&buffer.head), 0);
    gc_root_reset(&vm.heap, rm);
    return value_cell(&ta.head);
}

// Allocates a fresh buffer and a view of `kind` covering all of it.
private Value ta_alloc(VM* vm, i32 kind, i32 len) {
    if len < 0 { len = 0; }
    JsObject* ab = ab_new(vm, len * ta_elem_size(kind));
    vm_push(vm, value_cell(&ab.head));
    Value r = ta_make(vm, kind, ab, 0, len);
    vm_pop(vm);
    return r;
}

private JsObject* this_ta(VM* vm, Value thisv) {
    if !vm_is_typed_array(thisv) {
        vm_throw_error(vm, ERR_TYPE, "method called on a non-typed-array");
        return null;
    }
    return value_as_object(thisv);
}

// Prototype getters (so length/byteLength/byteOffset/buffer are not own
// properties, matching Node's hasOwnProperty / Object.keys behaviour).
private Value nat_ta_get_length(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    JsObject* o = this_ta(vm, thisv);
    if o == null { return value_undefined(); }
    return value_int(ta_len(vm, o));
}

private Value nat_ta_get_bytelength(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    JsObject* o = this_ta(vm, thisv);
    if o == null { return value_undefined(); }
    return value_int(ta_len(vm, o) * ta_elem_size(ta_kind(vm, o)));
}

private Value nat_ta_get_byteoffset(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    JsObject* o = this_ta(vm, thisv);
    if o == null { return value_undefined(); }
    return value_int(ta_off(vm, o));
}

private Value nat_ta_get_buffer(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    JsObject* o = this_ta(vm, thisv);
    if o == null { return value_undefined(); }
    JsObject* buf = ta_buffer(vm, o);
    return buf == null ? value_undefined() : value_cell(&buf.head);
}

private Value nat_ab_get_bytelength(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    if !is_arraybuffer(vm, thisv) {
        vm_throw_error(vm, ERR_TYPE, "Method get ArrayBuffer.prototype.byteLength called on incompatible receiver");
        return value_undefined();
    }
    return value_int(ab_len(vm, value_as_object(thisv)));
}

private Value nat_arraybuffer_ctor(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    i32 len = to_int_arg(arg_at(args, argc, 0));
    if len < 0 {
        vm_throw_error(vm, ERR_RANGE, "Invalid array buffer length");
        return value_undefined();
    }
    return value_cell(&ab_new(vm, len).head);
}

private Value nat_ab_slice(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    if !is_arraybuffer(vm, thisv) { return value_undefined(); }
    JsObject* ab = value_as_object(thisv);
    i32 len = ab_len(vm, ab);
    i32 b = buf_clamp(argc > 0 ? to_int_arg(arg_at(args, argc, 0)) : 0, len);
    i32 e = len;
    if argc > 1 && !value_is_undefined(arg_at(args, argc, 1)) {
        e = buf_clamp(to_int_arg(arg_at(args, argc, 1)), len);
    }
    if e < b { e = b; }
    i32 n = e - b;
    JsObject* nb = ab_new(vm, n);
    GcBytes* src = value_as_bytes(*(ab.elems));
    GcBytes* dst = value_as_bytes(*(nb.elems));
    if n > 0 { memcpy(gb_data(dst), gb_data(src) + b, cast(i64, n)); }
    return value_cell(&nb.head);
}

private Value nat_ab_isview(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    Value v = arg_at(args, argc, 0);
    if vm_is_typed_array(v) || is_dataview(vm, v) { return value_bool(true); }
    return value_bool(false);
}

// The one typed-array constructor; the element kind comes from env0, set
// per global (Int8Array..Float64Array) at install time.
private Value nat_ta_ctor(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    i32 kind = value_as_int(value_as_native(callee).env0);
    i32 esz = ta_elem_size(kind);
    Value a0 = arg_at(args, argc, 0);

    if is_arraybuffer(vm, a0) {
        JsObject* ab = value_as_object(a0);
        i32 ablen = ab_len(vm, ab);
        i32 boff = argc > 1 ? to_int_arg(arg_at(args, argc, 1)) : 0;
        if boff < 0 { boff = 0; }
        i32 len;
        if argc > 2 && !value_is_undefined(arg_at(args, argc, 2)) {
            len = to_int_arg(arg_at(args, argc, 2));
        } else {
            len = (ablen - boff) / esz;
        }
        if len < 0 { len = 0; }
        return ta_make(vm, kind, ab, boff, len);
    }
    if value_is_object(a0) {
        // Copy from an array, typed array, iterable, or array-like.
        Value[1] fa = { a0 };
        Value arr = nat_array_from(vmp, callee, value_undefined(), &fa[0], 1);
        if vm.has_pending { return value_undefined(); }
        vm_push(vm, arr);
        JsObject* sa = value_as_object(arr);
        i32 n = sa.elen;
        Value rv = ta_alloc(vm, kind, n);
        vm_push(vm, rv);
        JsObject* out = value_as_object(rv);
        for i32 i = 0; i < n; i++ {
            vm_ta_set(vm, out, i, js_array_get(sa, i));
        }
        vm.sp -= 2;
        return rv;
    }
    i32 len = value_is_number(a0) ? to_int_arg(a0) : 0;
    if len < 0 {
        vm_throw_error(vm, ERR_RANGE, "Invalid typed array length");
        return value_undefined();
    }
    return ta_alloc(vm, kind, len);
}

private Value nat_ta_from(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    i32 kind = value_as_int(value_as_native(callee).env0);
    Value src = arg_at(args, argc, 0);
    Value mapfn = arg_at(args, argc, 1);
    Value[2] fa = { src, mapfn };
    Value arr = nat_array_from(vmp, callee, value_undefined(), &fa[0], value_is_callable(mapfn) ? 2 : 1);
    if vm.has_pending { return value_undefined(); }
    vm_push(vm, arr);
    JsObject* sa = value_as_object(arr);
    i32 n = sa.elen;
    Value rv = ta_alloc(vm, kind, n);
    vm_push(vm, rv);
    JsObject* out = value_as_object(rv);
    for i32 i = 0; i < n; i++ {
        vm_ta_set(vm, out, i, js_array_get(sa, i));
    }
    vm.sp -= 2;
    return rv;
}

private Value nat_ta_of(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    i32 kind = value_as_int(value_as_native(callee).env0);
    Value rv = ta_alloc(vm, kind, argc);
    vm_push(vm, rv);
    JsObject* out = value_as_object(rv);
    for i32 i = 0; i < argc; i++ {
        vm_ta_set(vm, out, i, *(args + i));
    }
    vm_pop(vm);
    return rv;
}

// Normalizes a relative index (negatives count from the end) into [0,len].
private i32 ta_rel(i32 i, i32 len) {
    if i < 0 {
        i = len + i;
        if i < 0 { i = 0; }
    } else if i > len {
        i = len;
    }
    return i;
}

private Value nat_ta_at(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    JsObject* o = this_ta(vm, thisv);
    if o == null { return value_undefined(); }
    i32 len = ta_len(vm, o);
    i32 i = to_int_arg(arg_at(args, argc, 0));
    if i < 0 { i += len; }
    if i < 0 || i >= len { return value_undefined(); }
    return vm_ta_get(vm, o, i);
}

private Value nat_ta_fill(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    JsObject* o = this_ta(vm, thisv);
    if o == null { return value_undefined(); }
    i32 len = ta_len(vm, o);
    Value v = arg_at(args, argc, 0);
    i32 start = argc > 1 ? ta_rel(to_int_sat(arg_at(args, argc, 1)), len) : 0;
    i32 end = len;
    if argc > 2 && !value_is_undefined(arg_at(args, argc, 2)) {
        end = ta_rel(to_int_sat(arg_at(args, argc, 2)), len);
    }
    for i32 i = start; i < end; i++ { vm_ta_set(vm, o, i, v); }
    return thisv;
}

private Value nat_ta_reverse(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    JsObject* o = this_ta(vm, thisv);
    if o == null { return value_undefined(); }
    i32 len = ta_len(vm, o);
    for i32 i = 0; i < len / 2; i++ {
        Value a = vm_ta_get(vm, o, i);
        Value b = vm_ta_get(vm, o, len - 1 - i);
        vm_ta_set(vm, o, i, b);
        vm_ta_set(vm, o, len - 1 - i, a);
    }
    return thisv;
}

private Value nat_ta_join(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    JsObject* o = this_ta(vm, thisv);
    if o == null { return value_undefined(); }
    i32 len = ta_len(vm, o);
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
    for i32 i = 0; i < len; i++ {
        if i > 0 { str_buf_add(&sb, sep); }
        Value es = js_to_string_value(vm, vm_ta_get(vm, o, i));
        gc_root(&vm.heap, es);
        str_buf_add(&sb, sview(es));
    }
    Value r = new_str(vm, str_buf_to_str(&sb));
    str_buf_free(&sb);
    gc_root_reset(&vm.heap, rm);
    return r;
}

private Value nat_ta_tostring(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    return nat_ta_join(vmp, callee, thisv, null, 0);
}

private Value nat_ta_indexof(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    JsObject* o = this_ta(vm, thisv);
    if o == null { return value_int(-1); }
    i32 len = ta_len(vm, o);
    f64 s = js_to_number(arg_at(args, argc, 0));
    i32 start = argc > 1 ? to_int_arg(arg_at(args, argc, 1)) : 0;
    if start < 0 { start = len + start; if start < 0 { start = 0; } }
    for i32 i = start; i < len; i++ {
        if js_to_number(vm_ta_get(vm, o, i)) == s { return value_int(i); }
    }
    return value_int(-1);
}

private Value nat_ta_lastindexof(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    JsObject* o = this_ta(vm, thisv);
    if o == null { return value_int(-1); }
    i32 len = ta_len(vm, o);
    f64 s = js_to_number(arg_at(args, argc, 0));
    i32 start = len - 1;
    if argc > 1 {
        start = to_int_arg(arg_at(args, argc, 1));
        if start < 0 { start = len + start; }
        if start >= len { start = len - 1; }
    }
    for i32 i = start; i >= 0; i-- {
        if js_to_number(vm_ta_get(vm, o, i)) == s { return value_int(i); }
    }
    return value_int(-1);
}

private Value nat_ta_includes(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    JsObject* o = this_ta(vm, thisv);
    if o == null { return value_bool(false); }
    i32 len = ta_len(vm, o);
    f64 s = js_to_number(arg_at(args, argc, 0));
    bool snan = s != s;
    i32 start = argc > 1 ? to_int_arg(arg_at(args, argc, 1)) : 0;
    if start < 0 { start = len + start; if start < 0 { start = 0; } }
    for i32 i = start; i < len; i++ {
        f64 e = js_to_number(vm_ta_get(vm, o, i));
        if e == s { return value_bool(true); }
        if snan && e != e { return value_bool(true); }
    }
    return value_bool(false);
}

private Value nat_ta_subarray(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    JsObject* o = this_ta(vm, thisv);
    if o == null { return value_undefined(); }
    i32 len = ta_len(vm, o);
    i32 kind = ta_kind(vm, o);
    i32 boff = ta_off(vm, o);
    i32 esz = ta_elem_size(kind);
    JsObject* buf = ta_buffer(vm, o);
    i32 b = argc > 0 ? ta_rel(to_int_sat(arg_at(args, argc, 0)), len) : 0;
    i32 e = len;
    if argc > 1 && !value_is_undefined(arg_at(args, argc, 1)) {
        e = ta_rel(to_int_sat(arg_at(args, argc, 1)), len);
    }
    if e < b { e = b; }
    return ta_make(vm, kind, buf, boff + b * esz, e - b);
}

private Value nat_ta_slice(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    JsObject* o = this_ta(vm, thisv);
    if o == null { return value_undefined(); }
    i32 len = ta_len(vm, o);
    i32 kind = ta_kind(vm, o);
    i32 b = argc > 0 ? ta_rel(to_int_sat(arg_at(args, argc, 0)), len) : 0;
    i32 e = len;
    if argc > 1 && !value_is_undefined(arg_at(args, argc, 1)) {
        e = ta_rel(to_int_sat(arg_at(args, argc, 1)), len);
    }
    if e < b { e = b; }
    i32 n = e - b;
    i32 rm = gc_root_mark(&vm.heap);
    gc_root(&vm.heap, thisv);
    Value rv = ta_alloc(vm, kind, n);
    gc_root(&vm.heap, rv);
    JsObject* out = value_as_object(rv);
    for i32 i = 0; i < n; i++ { vm_ta_set(vm, out, i, vm_ta_get(vm, o, b + i)); }
    gc_root_reset(&vm.heap, rm);
    return rv;
}

private Value nat_ta_set_meth(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    JsObject* o = this_ta(vm, thisv);
    if o == null { return value_undefined(); }
    i32 len = ta_len(vm, o);
    i32 offset = argc > 1 ? to_int_arg(arg_at(args, argc, 1)) : 0;
    if offset < 0 {
        vm_throw_error(vm, ERR_RANGE, "offset is out of bounds");
        return value_undefined();
    }
    // Snapshot the source into a plain array so overlapping views are safe.
    Value[1] fa = { arg_at(args, argc, 0) };
    Value arr = nat_array_from(vmp, callee, value_undefined(), &fa[0], 1);
    if vm.has_pending { return value_undefined(); }
    vm_push(vm, arr);
    JsObject* sa = value_as_object(arr);
    i32 n = sa.elen;
    if offset + n > len {
        vm_pop(vm);
        vm_throw_error(vm, ERR_RANGE, "offset is out of bounds");
        return value_undefined();
    }
    for i32 i = 0; i < n; i++ { vm_ta_set(vm, o, offset + i, js_array_get(sa, i)); }
    vm_pop(vm);
    return value_undefined();
}

// Shared implementation for the callback iterators (map/filter/... modes).
private Value ta_iterate(VM* vm, Value thisv, Value* args, i32 argc, i32 mode) {
    JsObject* o = this_ta(vm, thisv);
    if o == null { return value_undefined(); }
    Value fun = arg_at(args, argc, 0);
    if !value_is_callable(fun) {
        vm_throw_error(vm, ERR_TYPE, "callback is not a function");
        return value_undefined();
    }
    i32 len = ta_len(vm, o);
    i32 kind = ta_kind(vm, o);
    i32 rm = gc_root_mark(&vm.heap);
    JsObject* out = null;
    JsObject* tmp = null;
    if mode == IT_MAP {
        Value rv = ta_alloc(vm, kind, len);
        gc_root(&vm.heap, rv);
        out = value_as_object(rv);
    } else if mode == IT_FILTER {
        tmp = js_new_array(&vm.heap, vm.array_proto);
        gc_root(&vm.heap, value_cell(&tmp.head));
    }
    i32 kept = 0;
    for i32 i = 0; i < len; i++ {
        Value e = vm_ta_get(vm, o, i);
        Value[3] cargs = { e, value_int(i), thisv };
        Value r = vm_call_value(vm, fun, value_undefined(), &cargs[0], 3);
        if vm.has_pending { gc_root_reset(&vm.heap, rm); return value_undefined(); }
        if mode == IT_MAP {
            vm_ta_set(vm, out, i, r);
        } else if mode == IT_FILTER {
            if js_truthy(r) { js_array_set(tmp, kept, e); kept++; }
        } else if mode == IT_SOME {
            if js_truthy(r) { gc_root_reset(&vm.heap, rm); return value_bool(true); }
        } else if mode == IT_EVERY {
            if !js_truthy(r) { gc_root_reset(&vm.heap, rm); return value_bool(false); }
        } else if mode == IT_FIND {
            if js_truthy(r) { gc_root_reset(&vm.heap, rm); return e; }
        } else if mode == IT_FINDINDEX {
            if js_truthy(r) { gc_root_reset(&vm.heap, rm); return value_int(i); }
        }
    }
    if mode == IT_MAP {
        Value rv = value_cell(&out.head);
        gc_root_reset(&vm.heap, rm);
        return rv;
    }
    if mode == IT_FILTER {
        Value rv = ta_alloc(vm, kind, kept);
        vm_push(vm, rv);
        JsObject* res = value_as_object(rv);
        for i32 i = 0; i < kept; i++ { vm_ta_set(vm, res, i, js_array_get(tmp, i)); }
        vm.sp--;
        gc_root_reset(&vm.heap, rm);
        return rv;
    }
    gc_root_reset(&vm.heap, rm);
    if mode == IT_SOME { return value_bool(false); }
    if mode == IT_EVERY { return value_bool(true); }
    if mode == IT_FINDINDEX { return value_int(-1); }
    return value_undefined();
}

private Value nat_ta_map(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    return ta_iterate(as_vm(vmp), thisv, args, argc, IT_MAP);
}
private Value nat_ta_filter(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    return ta_iterate(as_vm(vmp), thisv, args, argc, IT_FILTER);
}
private Value nat_ta_foreach(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    return ta_iterate(as_vm(vmp), thisv, args, argc, IT_FOREACH);
}
private Value nat_ta_some(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    return ta_iterate(as_vm(vmp), thisv, args, argc, IT_SOME);
}
private Value nat_ta_every(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    return ta_iterate(as_vm(vmp), thisv, args, argc, IT_EVERY);
}
private Value nat_ta_find(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    return ta_iterate(as_vm(vmp), thisv, args, argc, IT_FIND);
}
private Value nat_ta_findindex(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    return ta_iterate(as_vm(vmp), thisv, args, argc, IT_FINDINDEX);
}

private Value ta_reduce_impl(VM* vm, Value thisv, Value* args, i32 argc, bool right) {
    JsObject* o = this_ta(vm, thisv);
    if o == null { return value_undefined(); }
    Value fun = arg_at(args, argc, 0);
    if !value_is_callable(fun) {
        vm_throw_error(vm, ERR_TYPE, "callback is not a function");
        return value_undefined();
    }
    i32 len = ta_len(vm, o);
    i32 i = right ? len - 1 : 0;
    i32 step = right ? -1 : 1;
    Value acc;
    if argc > 1 {
        acc = *(args + 1);
    } else {
        if len == 0 {
            vm_throw_error(vm, ERR_TYPE, "Reduce of empty array with no initial value");
            return value_undefined();
        }
        acc = vm_ta_get(vm, o, i);
        i += step;
    }
    i32 rm = gc_root_mark(&vm.heap);
    i32 seen = right ? (len - 1 - i) : i;
    while seen < len {
        gc_root(&vm.heap, acc);
        Value[4] cargs = { acc, vm_ta_get(vm, o, i), value_int(i), thisv };
        acc = vm_call_value(vm, fun, value_undefined(), &cargs[0], 4);
        gc_root_reset(&vm.heap, rm);
        if vm.has_pending { return value_undefined(); }
        i += step;
        seen++;
    }
    return acc;
}

private Value nat_ta_reduce(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    return ta_reduce_impl(as_vm(vmp), thisv, args, argc, false);
}
private Value nat_ta_reduceright(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    return ta_reduce_impl(as_vm(vmp), thisv, args, argc, true);
}

private Value nat_ta_iter_next(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    JsNative* me = value_as_native(callee);
    Value src = me.env0;
    i32 i = value_as_int(me.env1);
    JsObject* r = js_new_object(&vm.heap, vm.object_proto);
    vm_push(vm, value_cell(&r.head));
    JsObject* o = value_as_object(src);
    i32 len = ta_len(vm, o);
    if i >= len {
        js_set_prop(r, vm_atom(vm, "done"), value_bool(true));
        js_set_prop(r, vm_atom(vm, "value"), value_undefined());
    } else {
        me.env1 = value_int(i + 1);
        i32 kind = value_as_int(me.env2);
        Value elem = vm_ta_get(vm, o, i);
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

private Value make_ta_iterator(VM* vm, Value src, i32 kind) {
    i32 rm = gc_root_mark(&vm.heap);
    gc_root(&vm.heap, src);
    JsObject* it = js_new_object(&vm.heap, vm.object_proto);
    gc_root(&vm.heap, value_cell(&it.head));
    JsNative* nx = js_new_native(&vm.heap, &nat_ta_iter_next, "next");
    nx.env0 = src;
    nx.env1 = value_int(0);
    nx.env2 = value_int(kind);
    js_set_prop(it, vm_atom(vm, "next"), value_cell(&nx.head));
    JsNative* si = js_new_native(&vm.heap, &nat_return_this, "[Symbol.iterator]");
    js_set_prop(it, vm_sym_iterator_id(vm), value_cell(&si.head));
    gc_root_reset(&vm.heap, rm);
    return value_cell(&it.head);
}

private Value nat_ta_values(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    if this_ta(vm, thisv) == null { return value_undefined(); }
    return make_ta_iterator(vm, thisv, 0);
}
private Value nat_ta_keys(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    if this_ta(vm, thisv) == null { return value_undefined(); }
    return make_ta_iterator(vm, thisv, 1);
}
private Value nat_ta_entries(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    if this_ta(vm, thisv) == null { return value_undefined(); }
    return make_ta_iterator(vm, thisv, 2);
}

// --- DataView ---------------------------------------------------------------

// Reads a value of `kind` from `base`, honouring endianness (native x64 is
// little-endian, so a big-endian read gathers the bytes reversed first).
private Value dv_read(u8* base, i32 kind, bool le) {
    i32 sz = ta_elem_size(kind);
    u8[8] tmp;
    for i32 i = 0; i < sz; i++ {
        *(&tmp[0] + i) = le ? *(base + i) : *(base + sz - 1 - i);
    }
    return ta_read(&tmp[0], kind);
}

private void dv_write(u8* base, i32 kind, f64 num, bool le) {
    i32 sz = ta_elem_size(kind);
    u8[8] tmp;
    ta_write(&tmp[0], kind, num);
    for i32 i = 0; i < sz; i++ {
        *(base + i) = le ? *(&tmp[0] + i) : *(&tmp[0] + sz - 1 - i);
    }
}

private Value nat_dataview_ctor(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    Value a0 = arg_at(args, argc, 0);
    if !is_arraybuffer(vm, a0) {
        vm_throw_error(vm, ERR_TYPE, "First argument to DataView constructor must be an ArrayBuffer");
        return value_undefined();
    }
    JsObject* ab = value_as_object(a0);
    i32 ablen = ab_len(vm, ab);
    i32 boff = argc > 1 ? to_int_arg(arg_at(args, argc, 1)) : 0;
    if boff < 0 { boff = 0; }
    i32 blen;
    if argc > 2 && !value_is_undefined(arg_at(args, argc, 2)) {
        blen = to_int_arg(arg_at(args, argc, 2));
    } else {
        blen = ablen - boff;
    }
    if blen < 0 { blen = 0; }
    i32 rm = gc_root_mark(&vm.heap);
    gc_root(&vm.heap, a0);
    JsObject* dv = js_new_object(&vm.heap, vm.dataview_proto);
    gc_root(&vm.heap, value_cell(&dv.head));
    GcBytes* gb = value_as_bytes(*(ab.elems));
    js_array_set(dv, 0, value_cell(&gb.head));
    props_set_desc(&dv.props, vm.atom_ta_off, value_int(boff), 0);
    props_set_desc(&dv.props, vm.atom_ta_len, value_int(blen), 0);
    props_set_desc(&dv.props, bi_atom(vm, "%tabuf"), value_cell(&ab.head), 0);
    gc_root_reset(&vm.heap, rm);
    return value_cell(&dv.head);   // buffer/byteOffset/byteLength are getters
}

private Value nat_dv_get_buffer(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    if !is_dataview(vm, thisv) { return value_undefined(); }
    Value* p = props_get(&value_as_object(thisv).props, bi_atom(vm, "%tabuf"));
    return p == null ? value_undefined() : *p;
}

private Value nat_dv_get_bytelength(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    if !is_dataview(vm, thisv) { return value_undefined(); }
    return value_int(ta_len(vm, value_as_object(thisv)));
}

private Value nat_dv_get_byteoffset(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    if !is_dataview(vm, thisv) { return value_undefined(); }
    return value_int(ta_off(vm, value_as_object(thisv)));
}

private Value nat_dv_get(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    if !is_dataview(vm, thisv) {
        vm_throw_error(vm, ERR_TYPE, "Method DataView.prototype.get called on incompatible receiver");
        return value_undefined();
    }
    JsObject* dv = value_as_object(thisv);
    i32 kind = value_as_int(value_as_native(callee).env0);
    i32 sz = ta_elem_size(kind);
    i32 off = to_int_arg(arg_at(args, argc, 0));
    bool le = kind <= 2 ? false : js_truthy(arg_at(args, argc, 1));
    i32 len = ta_len(vm, dv);
    if off < 0 || off + sz > len {
        vm_throw_error(vm, ERR_RANGE, "Offset is outside the bounds of the DataView");
        return value_undefined();
    }
    GcBytes* gb = value_as_bytes(*(dv.elems));
    return dv_read(gb_data(gb) + ta_off(vm, dv) + off, kind, le);
}

private Value nat_dv_set(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    if !is_dataview(vm, thisv) {
        vm_throw_error(vm, ERR_TYPE, "Method DataView.prototype.set called on incompatible receiver");
        return value_undefined();
    }
    JsObject* dv = value_as_object(thisv);
    i32 kind = value_as_int(value_as_native(callee).env0);
    i32 sz = ta_elem_size(kind);
    i32 off = to_int_arg(arg_at(args, argc, 0));
    f64 num = js_to_number(arg_at(args, argc, 1));
    bool le = kind <= 2 ? false : js_truthy(arg_at(args, argc, 2));
    i32 len = ta_len(vm, dv);
    if off < 0 || off + sz > len {
        vm_throw_error(vm, ERR_RANGE, "Offset is outside the bounds of the DataView");
        return value_undefined();
    }
    GcBytes* gb = value_as_bytes(*(dv.elems));
    dv_write(gb_data(gb) + ta_off(vm, dv) + off, kind, num, le);
    return value_undefined();
}

private void dv_get(VM* vm, str name, i32 kind) {
    JsNative* n = js_new_native(&vm.heap, &nat_dv_get, name);
    n.env0 = value_int(kind);
    props_set_desc(&vm.dataview_proto.props, bi_atom(vm, name), value_cell(&n.head), METHOD_ATTRS);
}

private void dv_set_m(VM* vm, str name, i32 kind) {
    JsNative* n = js_new_native(&vm.heap, &nat_dv_set, name);
    n.env0 = value_int(kind);
    props_set_desc(&vm.dataview_proto.props, bi_atom(vm, name), value_cell(&n.head), METHOD_ATTRS);
}

private void dataview_install(VM* vm) {
    vm.dataview_proto = js_new_object(&vm.heap, vm.object_proto);
    JsNative* ctor = def_global_fn(vm, "DataView", &nat_dataview_ctor);
    props_set_desc(&ctor.props, vm.atom_prototype, value_cell(&vm.dataview_proto.head), 0);
    link_ctor(vm, vm.dataview_proto, ctor);
    def_accessor(vm, vm.dataview_proto, "buffer", &nat_dv_get_buffer);
    def_accessor(vm, vm.dataview_proto, "byteLength", &nat_dv_get_bytelength);
    def_accessor(vm, vm.dataview_proto, "byteOffset", &nat_dv_get_byteoffset);
    dv_get(vm, "getInt8", 0);    dv_set_m(vm, "setInt8", 0);
    dv_get(vm, "getUint8", 1);   dv_set_m(vm, "setUint8", 1);
    dv_get(vm, "getInt16", 3);   dv_set_m(vm, "setInt16", 3);
    dv_get(vm, "getUint16", 4);  dv_set_m(vm, "setUint16", 4);
    dv_get(vm, "getInt32", 5);   dv_set_m(vm, "setInt32", 5);
    dv_get(vm, "getUint32", 6);  dv_set_m(vm, "setUint32", 6);
    dv_get(vm, "getFloat32", 7); dv_set_m(vm, "setFloat32", 7);
    dv_get(vm, "getFloat64", 8); dv_set_m(vm, "setFloat64", 8);
}

// Installs one concrete typed-array constructor (e.g. Uint8Array), whose
// prototype chains to the shared %TypedArray% prototype.
private void install_one_ta(VM* vm, i32 kind, str name) {
    JsObject* proto = js_new_object(&vm.heap, vm.ta_proto);
    vm.ta_protos[kind] = proto;
    JsNative* ctor = js_new_native(&vm.heap, &nat_ta_ctor, name);
    ctor.env0 = value_int(kind);
    vm_set_global(vm, name, value_cell(&ctor.head));
    props_set_desc(&ctor.props, vm.atom_prototype, value_cell(&proto.head), 0);
    link_ctor(vm, proto, ctor);
    num_const(vm, ctor, "BYTES_PER_ELEMENT", cast(f64, ta_elem_size(kind)));
    def_value(vm, proto, "BYTES_PER_ELEMENT", value_int(ta_elem_size(kind)));
    JsNative* fromn = js_new_native(&vm.heap, &nat_ta_from, "from");
    fromn.env0 = value_int(kind);
    props_set_desc(&ctor.props, bi_atom(vm, "from"), value_cell(&fromn.head), METHOD_ATTRS);
    JsNative* ofn = js_new_native(&vm.heap, &nat_ta_of, "of");
    ofn.env0 = value_int(kind);
    props_set_desc(&ctor.props, bi_atom(vm, "of"), value_cell(&ofn.head), METHOD_ATTRS);
}

private void typedarray_install(VM* vm) {
    // ArrayBuffer
    vm.arraybuffer_proto = js_new_object(&vm.heap, vm.object_proto);
    JsNative* abctor = def_global_fn(vm, "ArrayBuffer", &nat_arraybuffer_ctor);
    props_set_desc(&abctor.props, vm.atom_prototype, value_cell(&vm.arraybuffer_proto.head), 0);
    link_ctor(vm, vm.arraybuffer_proto, abctor);
    def_static(vm, abctor, "isView", &nat_ab_isview);
    def_method(vm, vm.arraybuffer_proto, "slice", &nat_ab_slice);
    def_accessor(vm, vm.arraybuffer_proto, "byteLength", &nat_ab_get_bytelength);

    // %TypedArray%.prototype: the shared method set for every kind.
    vm.ta_proto = js_new_object(&vm.heap, vm.object_proto);
    def_accessor(vm, vm.ta_proto, "length", &nat_ta_get_length);
    def_accessor(vm, vm.ta_proto, "byteLength", &nat_ta_get_bytelength);
    def_accessor(vm, vm.ta_proto, "byteOffset", &nat_ta_get_byteoffset);
    def_accessor(vm, vm.ta_proto, "buffer", &nat_ta_get_buffer);
    def_method(vm, vm.ta_proto, "set", &nat_ta_set_meth);
    def_method(vm, vm.ta_proto, "subarray", &nat_ta_subarray);
    def_method(vm, vm.ta_proto, "slice", &nat_ta_slice);
    def_method(vm, vm.ta_proto, "fill", &nat_ta_fill);
    def_method(vm, vm.ta_proto, "join", &nat_ta_join);
    def_method(vm, vm.ta_proto, "indexOf", &nat_ta_indexof);
    def_method(vm, vm.ta_proto, "lastIndexOf", &nat_ta_lastindexof);
    def_method(vm, vm.ta_proto, "includes", &nat_ta_includes);
    def_method(vm, vm.ta_proto, "forEach", &nat_ta_foreach);
    def_method(vm, vm.ta_proto, "map", &nat_ta_map);
    def_method(vm, vm.ta_proto, "filter", &nat_ta_filter);
    def_method(vm, vm.ta_proto, "reduce", &nat_ta_reduce);
    def_method(vm, vm.ta_proto, "reduceRight", &nat_ta_reduceright);
    def_method(vm, vm.ta_proto, "find", &nat_ta_find);
    def_method(vm, vm.ta_proto, "findIndex", &nat_ta_findindex);
    def_method(vm, vm.ta_proto, "some", &nat_ta_some);
    def_method(vm, vm.ta_proto, "every", &nat_ta_every);
    def_method(vm, vm.ta_proto, "at", &nat_ta_at);
    def_method(vm, vm.ta_proto, "reverse", &nat_ta_reverse);
    def_method(vm, vm.ta_proto, "keys", &nat_ta_keys);
    def_method(vm, vm.ta_proto, "values", &nat_ta_values);
    def_method(vm, vm.ta_proto, "entries", &nat_ta_entries);
    def_method(vm, vm.ta_proto, "toString", &nat_ta_tostring);
    JsNative* si = js_new_native(&vm.heap, &nat_ta_values, "[Symbol.iterator]");
    props_set_desc(&vm.ta_proto.props, vm_sym_iterator_id(vm), value_cell(&si.head), METHOD_ATTRS);

    install_one_ta(vm, 0, "Int8Array");
    install_one_ta(vm, 1, "Uint8Array");
    install_one_ta(vm, 2, "Uint8ClampedArray");
    install_one_ta(vm, 3, "Int16Array");
    install_one_ta(vm, 4, "Uint16Array");
    install_one_ta(vm, 5, "Int32Array");
    install_one_ta(vm, 6, "Uint32Array");
    install_one_ta(vm, 7, "Float32Array");
    install_one_ta(vm, 8, "Float64Array");

    dataview_install(vm);
}

// --- net (TCP sockets) ------------------------------------------------------
//
// Thin native primitives over net_os; all protocol logic (events, write
// queue, backpressure) lives in the JS `net` module (src/node_net.mc).
// The reactor calls net_reactor_dispatch for each ready handle, which
// simply hands off to the JS owner's __onReady(revents).

private void net_reactor_dispatch(VM* vm, i32 idx, i16 revents) {
    Value owner = vm_handle_owner(vm, idx);
    if !value_is_object(owner) { return; }
    Value m = value_undefined();
    if !vm_get_prop_value(vm, owner, bi_atom(vm, "__onReady"), &m) { return; }
    if !value_is_callable(m) { return; }
    i32 rm = gc_root_mark(&vm.heap);
    gc_root(&vm.heap, owner);
    Value[1] a = { value_int(cast(i32, revents)) };
    ignore vm_call_value(vm, m, owner, &a[0], 1);
    gc_root_reset(&vm.heap, rm);
}

// host string -> IPv4 (network order); empty/"0.0.0.0" = INADDR_ANY for a
// bind, loopback for a connect. 0 means resolution failed.
private u32 net_host_to_ip(VM* vm, Value hostv, bool for_bind) {
    if !value_is_string(hostv) { return for_bind ? cast(u32, 0) : NET_LOOPBACK_BE; }
    str h = sview(hostv);
    if h.len == 0 || str_equal(h, "0.0.0.0") { return for_bind ? cast(u32, 0) : NET_LOOPBACK_BE; }
    u8[256] cbuf;
    i32 n = h.len < 255 ? h.len : 255;
    for i32 i = 0; i < n; i++ { cbuf[i] = *(h.data + i); }
    cbuf[n] = 0;
    return net_os_resolve4(&cbuf[0]);
}

private Value nat_net_connect(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    u32 ip = net_host_to_ip(vm, arg_at(args, argc, 0), false);
    if ip == 0 { return value_int(-1); }
    i32 port = to_int_arg(arg_at(args, argc, 1));
    i64 fd = net_os_connect_start(ip, cast(u16, port));
    if fd == -1 { return value_int(-1); }
    i32 id = vm_handle_add(vm, fd, 0, value_undefined());
    vm_handle_set_interest(vm, id, NET_POLLOUT);
    return value_int(id);
}

private Value nat_net_listen(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    i32 port = to_int_arg(arg_at(args, argc, 0));
    u32 bind_ip = net_host_to_ip(vm, arg_at(args, argc, 1), true);
    i64 fd = net_os_listen4(bind_ip, cast(u16, port));
    if fd == -1 { return value_int(-1); }
    i32 id = vm_handle_add(vm, fd, 0, value_undefined());
    vm_handle_set_interest(vm, id, NET_POLLIN);
    return value_int(id);
}

private Value nat_net_accept(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    i64 lfd = vm_handle_fd(vm, to_int_arg(arg_at(args, argc, 0)));
    if lfd < 0 { return value_int(-1); }
    i64 afd = net_os_accept(lfd);
    if afd < 0 { return value_int(-1); }
    i32 nid = vm_handle_add(vm, afd, 0, value_undefined());
    vm_handle_set_interest(vm, nid, NET_POLLIN);
    return value_int(nid);
}

private Value nat_net_recv(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    i64 fd = vm_handle_fd(vm, to_int_arg(arg_at(args, argc, 0)));
    if fd < 0 { return value_int(-1); }
    u8[16384] buf;
    i32 n = net_os_recv(fd, &buf[0], 16384);
    if n > 0 { return buf_from_bytes(vm, &buf[0], n); }
    if n == 0 { return value_int(0); }            // clean EOF
    if n == NET_WOULDBLOCK { return value_null(); }
    return value_int(-1);                          // error
}

private Value nat_net_send(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    i64 fd = vm_handle_fd(vm, to_int_arg(arg_at(args, argc, 0)));
    Value bufv = arg_at(args, argc, 1);
    i32 off = to_int_arg(arg_at(args, argc, 2));
    if fd < 0 || !value_is_object(bufv) { return value_int(NET_ERR); }
    JsObject* o = value_as_object(bufv);
    bool is_ta = (o.obj_flags & OBJF_TYPEDARRAY) != 0;
    i32 len = is_ta ? ta_len(vm, o) : o.elen;
    if off < 0 { off = 0; }
    if off >= len { return value_int(0); }
    i32 chunk = len - off;
    if chunk > 16384 { chunk = 16384; }
    u8[16384] tmp;
    for i32 i = 0; i < chunk; i++ {
        i32 b = is_ta ? cast(i32, js_to_number(vm_ta_get(vm, o, off + i))) : buf_byte(o, off + i);
        tmp[i] = cast(u8, b & 0xFF);
    }
    return value_int(net_os_send(fd, &tmp[0], chunk));
}

private Value nat_net_want_write(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    i32 id = to_int_arg(arg_at(args, argc, 0));
    bool want = js_truthy(arg_at(args, argc, 1));
    vm_handle_set_interest(vm, id, want ? cast(i16, NET_POLLIN | NET_POLLOUT) : NET_POLLIN);
    return value_undefined();
}

private Value nat_net_close(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    i32 id = to_int_arg(arg_at(args, argc, 0));
    i64 fd = vm_handle_fd(vm, id);
    if fd >= 0 { net_os_close(fd); }
    vm_handle_close(vm, id);
    vm_handle_unref(vm, id);
    return value_undefined();
}

private Value nat_net_connect_result(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    i64 fd = vm_handle_fd(vm, to_int_arg(arg_at(args, argc, 0)));
    if fd < 0 { return value_int(NET_ERR); }
    return value_int(net_os_connect_result(fd));
}

private Value nat_net_set_owner(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    vm_handle_set_owner(vm, to_int_arg(arg_at(args, argc, 0)), arg_at(args, argc, 1));
    return value_undefined();
}

private Value nat_net_port(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    i64 fd = vm_handle_fd(vm, to_int_arg(arg_at(args, argc, 0)));
    if fd < 0 { return value_int(0); }
    return value_int(cast(i32, net_os_port(fd)));
}

private Value nat_net_ref(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    i32 id = to_int_arg(arg_at(args, argc, 0));
    if js_truthy(arg_at(args, argc, 1)) { vm_handle_ref(vm, id); } else { vm_handle_unref(vm, id); }
    return value_undefined();
}

// --- TLS (https) ------------------------------------------------------------
//
// A TLS session (src/tls_native.mc) is stashed on the handle's ext pointer.
// The JS TLSSocket calls these from its __onReady, the same dispatch path
// as plain sockets.

private i32 hex2(u8 c) {
    if c >= '0' && c <= '9' { return cast(i32, c) - '0'; }
    if c >= 'a' && c <= 'f' { return cast(i32, c) - 'a' + 10; }
    if c >= 'A' && c <= 'F' { return cast(i32, c) - 'A' + 10; }
    return 0;
}

private Value nat_tls_pin_ecdsa(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    Value hv = arg_at(args, argc, 0);
    if !value_is_string(hv) { return value_undefined(); }
    str h = sview(hv);
    if h.len < 64 { return value_undefined(); }
    u8[32] pin;
    for i32 i = 0; i < 32; i++ {
        pin[i] = cast(u8, (hex2(*(h.data + i * 2)) << 4) | hex2(*(h.data + i * 2 + 1)));
    }
    tls_set_ecdsa_pin(&pin[0]);
    return value_undefined();
}

private Value nat_tls_connect(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    u32 ip = net_host_to_ip(vm, arg_at(args, argc, 0), false);
    if ip == 0 { return value_int(-1); }
    i32 port = to_int_arg(arg_at(args, argc, 1));
    i64 fd = net_os_connect_start(ip, cast(u16, port));
    if fd == -1 { return value_int(-1); }
    Value sniv = arg_at(args, argc, 2);
    u8[256] sni;
    bool has_sni = value_is_string(sniv);
    if has_sni {
        str h = sview(sniv);
        i32 n = h.len < 255 ? h.len : 255;
        for i32 i = 0; i < n; i++ { sni[i] = *(h.data + i); }
        sni[n] = 0;
    }
    bool insecure = js_truthy(arg_at(args, argc, 3));
    TlsSession* s = tls_session_new(has_sni ? &sni[0] : null, insecure);
    if s == null { net_os_close(fd); return value_int(-1); }
    i32 id = vm_handle_add(vm, fd, 0, value_undefined());
    vm_handle_set_interest(vm, id, cast(i16, NET_POLLIN | NET_POLLOUT));
    vm_handle_set_ext(vm, id, cast(void*, s));
    return value_int(id);
}

private Value nat_tls_pump(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    i32 id = to_int_arg(arg_at(args, argc, 0));
    i64 fd = vm_handle_fd(vm, id);
    TlsSession* s = cast(TlsSession*, vm_handle_ext(vm, id));
    if s == null || fd < 0 { return value_int(TLS_ERR); }
    i32 flags = tls_pump(s, fd);
    i16 mask = NET_POLLIN;
    if (flags & TLS_WANT_WRITE) != 0 { mask = cast(i16, NET_POLLIN | NET_POLLOUT); }
    vm_handle_set_interest(vm, id, mask);
    return value_int(flags);
}

private Value nat_tls_read(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    i32 id = to_int_arg(arg_at(args, argc, 0));
    TlsSession* s = cast(TlsSession*, vm_handle_ext(vm, id));
    if s == null { return value_null(); }
    u8[16384] buf;
    i32 n = tls_read(s, &buf[0], 16384);
    if n <= 0 { return value_null(); }
    return buf_from_bytes(vm, &buf[0], n);
}

private Value nat_tls_write(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    i32 id = to_int_arg(arg_at(args, argc, 0));
    i64 fd = vm_handle_fd(vm, id);
    TlsSession* s = cast(TlsSession*, vm_handle_ext(vm, id));
    Value bufv = arg_at(args, argc, 1);
    i32 off = to_int_arg(arg_at(args, argc, 2));
    if s == null || fd < 0 || !value_is_object(bufv) { return value_int(NET_ERR); }
    JsObject* o = value_as_object(bufv);
    bool is_ta = (o.obj_flags & OBJF_TYPEDARRAY) != 0;
    i32 len = is_ta ? ta_len(vm, o) : o.elen;
    if off < 0 { off = 0; }
    if off >= len { return value_int(0); }
    i32 chunk = len - off;
    if chunk > 16384 { chunk = 16384; }
    u8[16384] tmp;
    for i32 i = 0; i < chunk; i++ {
        i32 b = is_ta ? cast(i32, js_to_number(vm_ta_get(vm, o, off + i))) : buf_byte(o, off + i);
        tmp[i] = cast(u8, b & 0xFF);
    }
    return value_int(tls_write(s, fd, &tmp[0], chunk) ? chunk : NET_ERR);
}

private Value nat_tls_close(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    i32 id = to_int_arg(arg_at(args, argc, 0));
    TlsSession* s = cast(TlsSession*, vm_handle_ext(vm, id));
    if s != null { tls_session_free(s); vm_handle_set_ext(vm, id, null); }
    i64 fd = vm_handle_fd(vm, id);
    if fd >= 0 { net_os_close(fd); }
    vm_handle_close(vm, id);
    vm_handle_unref(vm, id);
    return value_undefined();
}

private Value nat_tls_established(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    TlsSession* s = cast(TlsSession*, vm_handle_ext(vm, to_int_arg(arg_at(args, argc, 0))));
    return value_bool(s != null && tls_established(s));
}

// Human-readable reason when the handshake failed on certificate
// validation; null for transport-level failures.
private Value nat_tls_verify_error(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    TlsSession* s = cast(TlsSession*, vm_handle_ext(vm, to_int_arg(arg_at(args, argc, 0))));
    if s == null { return value_null(); }
    i32 code = tls_chain_error(s);
    if code == 0 { return value_null(); }
    return new_str(vm, tls_chain_err_str(code));
}

// True while outbound ciphertext is still queued: an ending socket must wait
// for it to drain before closing so the response is not truncated.
private Value nat_tls_wants_write(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    TlsSession* s = cast(TlsSession*, vm_handle_ext(vm, to_int_arg(arg_at(args, argc, 0))));
    return value_bool(s != null && tls_wants_write(s));
}

// Copy up to `cap` bytes out of a JS Buffer or typed array into `out`.
// Returns the count, or -1 if the value is not byte-like or overflows `cap`.
private i32 tls_js_bytes(VM* vm, Value bufv, u8* out, i32 cap) {
    if !value_is_object(bufv) { return 0 - 1; }
    JsObject* o = value_as_object(bufv);
    bool is_ta = (o.obj_flags & OBJF_TYPEDARRAY) != 0;
    i32 len = is_ta ? ta_len(vm, o) : o.elen;
    if len > cap { return 0 - 1; }
    for i32 i = 0; i < len; i++ {
        i32 b = is_ta ? cast(i32, js_to_number(vm_ta_get(vm, o, i))) : buf_byte(o, i);
        *(out + i) = cast(u8, b & 0xFF);
    }
    return len;
}

// __tls_server_ctx(certDer, keyDer): build a shared server context from an
// X.509 cert and its EC private key (both DER buffers). Returns a registry id
// or -1 (bad/unsupported key).
private Value nat_tls_server_ctx(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    u8[8192] cert;
    i32 clen = tls_js_bytes(vm, arg_at(args, argc, 0), &cert[0], 8192);
    u8[2048] key;
    i32 klen = tls_js_bytes(vm, arg_at(args, argc, 1), &key[0], 2048);
    if clen < 0 || klen < 0 { return value_int(-1); }
    i32 id = tls_server_ctx_new(&cert[0], cast(u64, clen), &key[0], cast(u64, klen));
    return value_int(id);
}

// __tls_server_wrap(handleId, ctxId): install a server TLS session on an
// already-accepted fd handle. The caller then re-owns the handle to a
// TLSSocket so the reactor pumps TLS instead of plain net.
private Value nat_tls_server_wrap(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    i32 id = to_int_arg(arg_at(args, argc, 0));
    i32 ctx_id = to_int_arg(arg_at(args, argc, 1));
    if vm_handle_fd(vm, id) < 0 { return value_int(-1); }
    TlsSession* s = tls_server_session_new(ctx_id);
    if s == null { return value_int(-1); }
    vm_handle_set_ext(vm, id, cast(void*, s));
    vm_handle_set_interest(vm, id, cast(i16, NET_POLLIN));
    return value_int(0);
}

// __tls_server_ctx_free(ctxId): release a server context on server.close.
private Value nat_tls_server_ctx_free(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    tls_server_ctx_free(to_int_arg(arg_at(args, argc, 0)));
    return value_undefined();
}

private void net_install(VM* vm) {
    ignore net_os_init();
    vm_set_reactor_hook(vm, &net_reactor_dispatch);
    ignore def_global_fn(vm, "__tls_connect", &nat_tls_connect);
    ignore def_global_fn(vm, "__tls_server_ctx", &nat_tls_server_ctx);
    ignore def_global_fn(vm, "__tls_server_wrap", &nat_tls_server_wrap);
    ignore def_global_fn(vm, "__tls_server_ctx_free", &nat_tls_server_ctx_free);
    ignore def_global_fn(vm, "__tls_pump", &nat_tls_pump);
    ignore def_global_fn(vm, "__tls_read", &nat_tls_read);
    ignore def_global_fn(vm, "__tls_write", &nat_tls_write);
    ignore def_global_fn(vm, "__tls_close", &nat_tls_close);
    ignore def_global_fn(vm, "__tls_established", &nat_tls_established);
    ignore def_global_fn(vm, "__tls_verify_error", &nat_tls_verify_error);
    ignore def_global_fn(vm, "__tls_wants_write", &nat_tls_wants_write);
    ignore def_global_fn(vm, "__tls_pin_ecdsa", &nat_tls_pin_ecdsa);
    ignore def_global_fn(vm, "__net_connect", &nat_net_connect);
    ignore def_global_fn(vm, "__net_listen", &nat_net_listen);
    ignore def_global_fn(vm, "__net_accept", &nat_net_accept);
    ignore def_global_fn(vm, "__net_recv", &nat_net_recv);
    ignore def_global_fn(vm, "__net_send", &nat_net_send);
    ignore def_global_fn(vm, "__net_want_write", &nat_net_want_write);
    ignore def_global_fn(vm, "__net_close", &nat_net_close);
    ignore def_global_fn(vm, "__net_connect_result", &nat_net_connect_result);
    ignore def_global_fn(vm, "__net_set_owner", &nat_net_set_owner);
    ignore def_global_fn(vm, "__net_port", &nat_net_port);
    ignore def_global_fn(vm, "__net_ref", &nat_net_ref);
}

private void buffer_install(VM* vm) {
    vm.buffer_proto = js_new_object(&vm.heap, vm.array_proto);
    JsNative* ctor = def_global_fn(vm, "Buffer", &nat_buffer_ctor);
    props_set_desc(&ctor.props, vm.atom_prototype, value_cell(&vm.buffer_proto.head), 0);
    link_ctor(vm, vm.buffer_proto, ctor);

    def_static(vm, ctor, "from", &nat_buffer_from);
    def_static(vm, ctor, "alloc", &nat_buffer_alloc);
    def_static(vm, ctor, "allocUnsafe", &nat_buffer_alloc);
    def_static(vm, ctor, "concat", &nat_buffer_concat);
    def_static(vm, ctor, "isBuffer", &nat_buffer_is_buffer);
    def_static(vm, ctor, "byteLength", &nat_buffer_byte_length);

    def_method(vm, vm.buffer_proto, "toString", &nat_buf_to_string);
    def_method(vm, vm.buffer_proto, "slice", &nat_buf_slice);
    def_method(vm, vm.buffer_proto, "subarray", &nat_buf_slice);
    def_method(vm, vm.buffer_proto, "equals", &nat_buf_equals);
    def_method(vm, vm.buffer_proto, "compare", &nat_buf_compare);
    def_method(vm, vm.buffer_proto, "copy", &nat_buf_copy);
    def_method(vm, vm.buffer_proto, "fill", &nat_buf_fill);
    def_method(vm, vm.buffer_proto, "write", &nat_buf_write);
    def_method(vm, vm.buffer_proto, "indexOf", &nat_buf_index_of);
    def_method(vm, vm.buffer_proto, "includes", &nat_buf_includes);
    def_method(vm, vm.buffer_proto, "toJSON", &nat_buf_to_json);
    def_method(vm, vm.buffer_proto, "readUInt8", &nat_buf_read_u8);
    def_method(vm, vm.buffer_proto, "readInt8", &nat_buf_read_i8);
    def_method(vm, vm.buffer_proto, "writeUInt8", &nat_buf_write_u8);
    def_method(vm, vm.buffer_proto, "readUInt16LE", &nat_buf_read_u16le);
    def_method(vm, vm.buffer_proto, "readUInt16BE", &nat_buf_read_u16be);
    def_method(vm, vm.buffer_proto, "writeUInt16LE", &nat_buf_write_u16le);
    def_method(vm, vm.buffer_proto, "writeUInt16BE", &nat_buf_write_u16be);
    def_method(vm, vm.buffer_proto, "readUInt32LE", &nat_buf_read_u32le);
    def_method(vm, vm.buffer_proto, "readUInt32BE", &nat_buf_read_u32be);
    def_method(vm, vm.buffer_proto, "writeUInt32LE", &nat_buf_write_u32le);
    def_method(vm, vm.buffer_proto, "writeUInt32BE", &nat_buf_write_u32be);
}

// --- TextEncoder / TextDecoder ----------------------------------------------
//
// The WHATWG encoding APIs over UTF-8 (plus latin1 decode). TextEncoder
// yields a Buffer (byte array) since there is no Uint8Array; TextDecoder
// reads any byte array-like.

private Value nat_textencoder_ctor(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    JsObject* inst = js_new_object(&vm.heap, vm.textenc_proto);
    return value_cell(&inst.head);
}

private Value nat_textencoder_encode(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    Value a = arg_at(args, argc, 0);
    Value s = value_is_undefined(a) ? new_str(vm, "") : js_to_string_value(vm, a);
    vm_push(vm, s);
    str v = sview(s);
    Value r = buf_from_bytes(vm, v.data, v.len);
    vm_pop(vm);
    return r;
}

private Value nat_textdecoder_ctor(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    JsObject* inst = js_new_object(&vm.heap, vm.textdec_proto);
    vm_push(vm, value_cell(&inst.head));
    str canon = "utf-8";
    Value label = arg_at(args, argc, 0);
    if value_is_string(label) {
        str l = sview(label);
        if ci_eq(l, "latin1") || ci_eq(l, "iso-8859-1") || ci_eq(l, "windows-1252") || ci_eq(l, "binary") {
            canon = "windows-1252";
        }
        // any other label (including unknown ones) is treated as utf-8
    }
    def_value(vm, inst, "encoding", new_str(vm, canon));
    def_value(vm, inst, "fatal", value_bool(false));
    def_value(vm, inst, "ignoreBOM", value_bool(false));
    vm_pop(vm);
    return value_cell(&inst.head);
}

private Value nat_textdecoder_decode(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    Value inp = arg_at(args, argc, 0);
    if !value_is_array(inp) { return new_str(vm, ""); }
    JsObject* a = value_as_object(inp);
    i32 enc = ENC_UTF8;
    Value encv;
    if vm_get_prop_value(vm, thisv, bi_atom(vm, "encoding"), &encv) && value_is_string(encv) {
        if !ci_eq(sview(encv), "utf-8") { enc = ENC_LATIN1; }
    }
    return bytes_to_str(vm, a, enc, 0, a.elen);
}

private void textcodec_install(VM* vm) {
    vm.textenc_proto = js_new_object(&vm.heap, vm.object_proto);
    JsNative* ec = def_global_fn(vm, "TextEncoder", &nat_textencoder_ctor);
    props_set_desc(&ec.props, vm.atom_prototype, value_cell(&vm.textenc_proto.head), 0);
    link_ctor(vm, vm.textenc_proto, ec);
    def_method(vm, vm.textenc_proto, "encode", &nat_textencoder_encode);
    def_value(vm, vm.textenc_proto, "encoding", new_str(vm, "utf-8"));

    vm.textdec_proto = js_new_object(&vm.heap, vm.object_proto);
    JsNative* dc = def_global_fn(vm, "TextDecoder", &nat_textdecoder_ctor);
    props_set_desc(&dc.props, vm.atom_prototype, value_cell(&vm.textdec_proto.head), 0);
    link_ctor(vm, vm.textdec_proto, dc);
    def_method(vm, vm.textdec_proto, "decode", &nat_textdecoder_decode);
}

// --- node built-in modules: path / fs ---------------------------------------
//
// Reached via `import path from 'path'` / `import fs from 'fs'` (and the
// `node:` prefix). The loader binds a synthetic module whose namespace
// carries `default` (the module object) plus every function as a named
// export, so all three import forms work.

when os(windows) {
    private bool path_is_sep(u8 c) { return c == '/' || c == '\\'; }
    private str path_sep_str() { return "\\"; }
    private u8 path_sep_ch() { return cast(u8, 92); }   // backslash
    private str path_delim_str() { return ";"; }
}
else when os(macos) || os(ios) || os(linux) || os(android) || os(wasm) {
    private bool path_is_sep(u8 c) { return c == '/'; }
    private str path_sep_str() { return "/"; }
    private u8 path_sep_ch() { return cast(u8, '/'); }
    private str path_delim_str() { return ":"; }
}
else {
    // No arm for this target. Add a `when os(...)` arm above rather
    // than assuming another platform's path conventions.
    tsmc_unsupported_target__add_a_when_os_arm _unsupported_path;
}

// Coerces arg[i] to a string and keeps it rooted for the caller (which
// must vm_pop once done reading the returned view).
private str path_arg(VM* vm, Value* args, i32 argc, i32 i) {
    Value sv = js_to_string_value(vm, arg_at(args, argc, i));
    vm_push(vm, sv);
    return sview(sv);
}

// Trailing separators removed, but a lone root (or "C:\") is kept.
private i32 path_trim_end(str p) {
    i32 end = p.len;
    while end > 1 && path_is_sep(*(p.data + end - 1)) { end--; }
    return end;
}

private i32 path_last_sep(str p, i32 end) {
    i32 last = -1;
    for i32 i = 0; i < end; i++ {
        if path_is_sep(*(p.data + i)) { last = i; }
    }
    return last;
}

private Value nat_path_dirname(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    str p = path_arg(vm, args, argc, 0);
    i32 end = path_trim_end(p);
    i32 last = path_last_sep(p, end);
    Value r;
    if last < 0 { r = new_str(vm, "."); }
    else {
        // last == 0 keeps the input's own leading separator (Node preserves
        // separator style; "/" -> "/", "\\" -> "\\").
        str d;
        d.data = p.data;
        d.len = last == 0 ? 1 : last;
        r = new_str(vm, d);
    }
    vm_pop(vm);
    return r;
}

private Value nat_path_basename(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    str p = path_arg(vm, args, argc, 0);
    i32 end = path_trim_end(p);
    i32 last = path_last_sep(p, end);
    str base;
    base.data = p.data + (last + 1);
    base.len = end - (last + 1);
    Value ev = arg_at(args, argc, 1);
    if value_is_string(ev) {
        str ext = sview(ev);
        if ext.len > 0 && ext.len < base.len {
            bool match = true;
            for i32 i = 0; i < ext.len; i++ {
                if *(base.data + base.len - ext.len + i) != *(ext.data + i) { match = false; break; }
            }
            if match { base.len = base.len - ext.len; }
        }
    }
    Value r = new_str(vm, base);
    vm_pop(vm);
    return r;
}

private Value nat_path_extname(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    str p = path_arg(vm, args, argc, 0);
    i32 end = path_trim_end(p);
    i32 start = path_last_sep(p, end) + 1;
    i32 dot = -1;
    for i32 i = start; i < end; i++ {
        if *(p.data + i) == '.' { dot = i; }
    }
    str e;
    if dot <= start { e.data = p.data; e.len = 0; }   // no dot, or leading dot only
    else { e.data = p.data + dot; e.len = end - dot; }
    Value r = new_str(vm, e);
    vm_pop(vm);
    return r;
}

private bool path_absolute(str p) {
    if p.len == 0 { return false; }
    if path_is_sep(*(p.data)) { return true; }
    when os(windows) {
        // drive-absolute: "C:\" or "C:/"
        if p.len >= 3 {
            u8 c0 = *(p.data);
            bool letter = (c0 >= 'A' && c0 <= 'Z') || (c0 >= 'a' && c0 <= 'z');
            if letter && *(p.data + 1) == ':' && path_is_sep(*(p.data + 2)) { return true; }
        }
    }
    return false;
}

private Value nat_path_isabsolute(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    str p = path_arg(vm, args, argc, 0);
    bool r = path_absolute(p);
    vm_pop(vm);
    return value_bool(r);
}

// Normalizes a path (collapse `.`/`..`/duplicate separators), preserving
// an absolute root, a Windows drive prefix, and a trailing separator.
private void path_norm_into(str_buf* out, str p) {
    i32 mark = out.len;
    i32 n = p.len;
    str root;
    root.data = p.data;
    root.len = 0;
    i32 i = 0;
    when os(windows) {
        if n >= 2 {
            u8 c0 = *(p.data);
            bool letter = (c0 >= 'A' && c0 <= 'Z') || (c0 >= 'a' && c0 <= 'z');
            if letter && *(p.data + 1) == ':' { root.len = 2; i = 2; }
        }
    }
    bool is_abs = i < n && path_is_sep(*(p.data + i));
    Vec<str> segs = vec_new<str>(8);
    while i < n {
        while i < n && path_is_sep(*(p.data + i)) { i++; }
        i32 start = i;
        while i < n && !path_is_sep(*(p.data + i)) { i++; }
        str seg;
        seg.data = p.data + start;
        seg.len = i - start;
        if seg.len == 0 { /* trailing */ }
        else if seg.len == 1 && *(seg.data) == '.' { /* skip */ }
        else if seg.len == 2 && *(seg.data) == '.' && *(seg.data + 1) == '.' {
            if segs.len > 0 {
                str top = vec_get(&segs, segs.len - 1);
                bool top_dd = top.len == 2 && *(top.data) == '.' && *(top.data + 1) == '.';
                if !top_dd { segs.len = segs.len - 1; }
                else if !is_abs { vec_push(&segs, seg); }
            } else if !is_abs { vec_push(&segs, seg); }
        }
        else { vec_push(&segs, seg); }
    }
    if root.len > 0 { str_buf_add(out, root); }
    if is_abs { str_buf_add_byte(out, path_sep_ch()); }
    for i32 k = 0; k < segs.len; k++ {
        if k > 0 { str_buf_add_byte(out, path_sep_ch()); }
        str_buf_add(out, vec_get(&segs, k));
    }
    bool had_trail = n > 0 && path_is_sep(*(p.data + n - 1));
    if had_trail && segs.len > 0 { str_buf_add_byte(out, path_sep_ch()); }
    if out.len == mark { str_buf_add(out, "."); }
    vec_free(&segs);
}

private Value nat_path_normalize(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    str p = path_arg(vm, args, argc, 0);
    str_buf out;
    str_buf_init(&out);
    path_norm_into(&out, p);
    Value r = new_str(vm, str_buf_to_str(&out));
    str_buf_free(&out);
    vm_pop(vm);
    return r;
}

private Value nat_path_join(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    str_buf raw;
    str_buf_init(&raw);
    i32 pushed = 0;
    bool any = false;
    for i32 i = 0; i < argc; i++ {
        Value sv = js_to_string_value(vm, arg_at(args, argc, i));
        vm_push(vm, sv);
        pushed++;
        str s = sview(sv);
        if s.len > 0 {
            if any { str_buf_add_byte(&raw, path_sep_ch()); }
            str_buf_add(&raw, s);
            any = true;
        }
    }
    str_buf out;
    str_buf_init(&out);
    if !any { str_buf_add(&out, "."); }
    else { path_norm_into(&out, str_buf_to_str(&raw)); }
    Value r = new_str(vm, str_buf_to_str(&out));
    str_buf_free(&out);
    str_buf_free(&raw);
    for i32 i = 0; i < pushed; i++ { vm_pop(vm); }
    return r;
}

private Value nat_path_resolve(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    str_buf acc;
    str_buf_init(&acc);
    bool have_abs = false;
    i32 pushed = 0;
    for i32 i = 0; i < argc; i++ {
        Value sv = js_to_string_value(vm, arg_at(args, argc, i));
        vm_push(vm, sv);
        pushed++;
        str s = sview(sv);
        if s.len == 0 { continue; }
        if path_absolute(s) {
            acc.len = 0;
            str_buf_add(&acc, s);
            have_abs = true;
        } else {
            if acc.len > 0 { str_buf_add_byte(&acc, path_sep_ch()); }
            str_buf_add(&acc, s);
        }
    }
    // still relative -> prepend cwd
    if !have_abs {
        Value cwd = os_cwd_str(vm);
        vm_push(vm, cwd);
        pushed++;
        str c = sview(cwd);
        str_buf pre;
        str_buf_init(&pre);
        str_buf_add(&pre, c);
        if acc.len > 0 { str_buf_add_byte(&pre, path_sep_ch()); str_buf_add(&pre, str_buf_to_str(&acc)); }
        acc.len = 0;
        str_buf_add(&acc, str_buf_to_str(&pre));
        str_buf_free(&pre);
    }
    str_buf out;
    str_buf_init(&out);
    path_norm_into(&out, str_buf_to_str(&acc));
    Value r = new_str(vm, str_buf_to_str(&out));
    str_buf_free(&out);
    str_buf_free(&acc);
    for i32 i = 0; i < pushed; i++ { vm_pop(vm); }
    return r;
}

private Value nat_path_parse(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    JsObject* o = js_new_object(&vm.heap, vm.object_proto);
    vm_push(vm, value_cell(&o.head));
    str p = path_arg(vm, args, argc, 0);
    i32 end = path_trim_end(p);
    i32 last = path_last_sep(p, end);
    // dir
    str dir;
    if last < 0 { dir.data = p.data; dir.len = 0; }
    else if last == 0 { dir.data = p.data; dir.len = 1; }
    else { dir.data = p.data; dir.len = last; }
    // base
    str base;
    base.data = p.data + (last + 1);
    base.len = end - (last + 1);
    // ext / name
    i32 dot = -1;
    for i32 i = 0; i < base.len; i++ { if *(base.data + i) == '.' { dot = i; } }
    str ext;
    str name;
    if dot <= 0 { ext.data = base.data; ext.len = 0; name = base; }
    else { ext.data = base.data + dot; ext.len = base.len - dot; name.data = base.data; name.len = dot; }
    str root;
    root.data = p.data;
    root.len = path_absolute(p) ? 1 : 0;
    when os(windows) {
        if p.len >= 3 && path_absolute(p) && *(p.data + 1) == ':' { root.len = 3; }
    }
    def_value_enum(vm, o, "root", new_str(vm, root));
    def_value_enum(vm, o, "dir", new_str(vm, dir));
    def_value_enum(vm, o, "base", new_str(vm, base));
    def_value_enum(vm, o, "ext", new_str(vm, ext));
    def_value_enum(vm, o, "name", new_str(vm, name));
    vm_pop(vm);   // p's string
    Value r = value_cell(&o.head);
    vm_pop(vm);   // o
    return r;
}

private void def_node_export(VM* vm, JsObject* mod, JsObject* ns, str name, NativeFn f) {
    JsNative* n = js_new_native(&vm.heap, f, name);
    Value v = value_cell(&n.head);
    props_set_desc(&mod.props, bi_atom(vm, name), v, PROP_DEFAULT);
    props_set_desc(&ns.props, bi_atom(vm, name), v, PROP_DEFAULT);
}

private void def_node_value(VM* vm, JsObject* mod, JsObject* ns, str name, Value v) {
    props_set_desc(&mod.props, bi_atom(vm, name), v, PROP_DEFAULT);
    props_set_desc(&ns.props, bi_atom(vm, name), v, PROP_DEFAULT);
}

// Builds a namespace: default = a fresh module object, named exports
// mirrored onto both. The namespace is permanently rooted; the module
// object stays reachable through the namespace's `default` slot.
private JsObject* new_node_module(VM* vm, JsObject** out_mod) {
    JsObject* ns = js_new_object(&vm.heap, null);
    gc_root(&vm.heap, value_cell(&ns.head));
    JsObject* mod = js_new_object(&vm.heap, vm.object_proto);
    props_set_desc(&ns.props, bi_atom(vm, "default"), value_cell(&mod.head), PROP_DEFAULT);
    *out_mod = mod;
    return ns;
}

// --- fs: OS layer (dir/type ops; read/write/stat use the file lib) ---

when os(windows) {
    private extern "kernel32.dll" i32 CreateDirectoryA(u8* path, void* sec);
    private extern "kernel32.dll" i32 DeleteFileA(u8* path);
    private extern "kernel32.dll" i32 RemoveDirectoryA(u8* path);
    private extern "kernel32.dll" i32 MoveFileExA(u8* src, u8* dst, u32 flags);
    private extern "kernel32.dll" u32 GetFileAttributesA(u8* path);
    // WIN32_FIND_DATAA: cFileName (u8[260]) at offset 44 after attrs + 3
    // FILETIMEs (24) + size hi/lo (8) + 2 reserved (8).
    struct _FindDataA {
        u32 attrs;
        u32 ct_lo; u32 ct_hi;
        u32 at_lo; u32 at_hi;
        u32 wt_lo; u32 wt_hi;
        u32 sz_hi; u32 sz_lo;
        u32 res0; u32 res1;
        u8[260] name;
        u8[14] altname;
    }
    private extern "kernel32.dll" i64 FindFirstFileA(u8* pattern, _FindDataA* data);
    private extern "kernel32.dll" i32 FindNextFileA(i64 h, _FindDataA* data);
    private extern "kernel32.dll" i32 FindClose(i64 h);
    private bool fs_mkdir1(u8* p) { return CreateDirectoryA(p, null) != 0; }
    private bool fs_rmdir1(u8* p) { return RemoveDirectoryA(p) != 0; }
    private bool fs_unlink1(u8* p) { return DeleteFileA(p) != 0; }
    private bool fs_rename1(u8* a, u8* b) { return MoveFileExA(a, b, 1) != 0; }  // REPLACE_EXISTING
    private bool fs_is_dir(u8* p) {
        u32 a = GetFileAttributesA(p);
        if a == 0xFFFFFFFF { return false; }
        return (a & 0x10) != 0;   // FILE_ATTRIBUTE_DIRECTORY
    }
    // FILETIME 100ns ticks since 1601 -> ms since Unix epoch
    private f64 fs_mtime_ms(u64 mt) { return cast(f64, cast(i64, mt)) / 10000.0 - 11644473600000.0; }
    private void fs_readdir_into(VM* vm, str dir, JsObject* arr) {
        str_buf pat;
        str_buf_init(&pat);
        str_buf_add(&pat, dir);
        str_buf_add_byte(&pat, path_sep_ch());
        str_buf_add_byte(&pat, cast(u8, '*'));
        u8* cpat = str_to_cstr(str_buf_to_str(&pat));
        str_buf_free(&pat);
        _FindDataA fd;
        i64 h = FindFirstFileA(cpat, &fd);
        free(cpat);
        if h == 0 - 1 { return; }   // INVALID_HANDLE_VALUE
        i32 idx = 0;
        while true {
            str name = str_from_cstr(&fd.name[0]);
            bool dot = (name.len == 1 && *(name.data) == '.')
                || (name.len == 2 && *(name.data) == '.' && *(name.data + 1) == '.');
            if !dot { js_array_set(arr, idx, new_str(vm, name)); idx++; }
            if FindNextFileA(h, &fd) == 0 { break; }
        }
        ignore FindClose(h);
    }
}
else when os(wasm) {
    // Sandbox: the host import surface is read-only (open/read/close),
    // so mutations fail and directories are always empty. Callers
    // surface these as the usual fs errors.
    private bool fs_mkdir1(u8* p) { return false; }
    private bool fs_rmdir1(u8* p) { return false; }
    private bool fs_unlink1(u8* p) { return false; }
    private bool fs_rename1(u8* a, u8* b) { return false; }
    private bool fs_is_dir(u8* p) { return false; }
    private f64 fs_mtime_ms(u64 mt) { return cast(f64, cast(i64, mt)) / 1000000.0; }
    private void fs_readdir_into(VM* vm, str dir, JsObject* arr) { }
}
else when os(macos) || os(ios) || os(linux) || os(android) {
    when os(macos) || os(ios) {
        private extern "libSystem.B.dylib" i32 mkdir(u8* path, u32 mode);
        private extern "libSystem.B.dylib" i32 unlink(u8* path);
        private extern "libSystem.B.dylib" i32 rmdir(u8* path);
        private extern "libSystem.B.dylib" i32 rename(u8* old, u8* nw);
        private extern "libSystem.B.dylib" void* opendir(u8* path);
        private extern "libSystem.B.dylib" u8* readdir(void* dp);
        private extern "libSystem.B.dylib" i32 closedir(void* dp);
        // struct dirent (Darwin 64-bit inode): d_name at offset 21.
        private u8* dirent_name(u8* de) { return de + 21; }
    }
    else when os(android) {
        private extern "libc.so" i32 mkdir(u8* path, u32 mode);
        private extern "libc.so" i32 unlink(u8* path);
        private extern "libc.so" i32 rmdir(u8* path);
        private extern "libc.so" i32 rename(u8* old, u8* nw);
        private extern "libc.so" void* opendir(u8* path);
        private extern "libc.so" u8* readdir(void* dp);
        private extern "libc.so" i32 closedir(void* dp);
        // struct dirent (Android/Linux): d_name at offset 19.
        private u8* dirent_name(u8* de) { return de + 19; }
    }
    else {
        private extern "libc.so.6" i32 mkdir(u8* path, u32 mode);
        private extern "libc.so.6" i32 unlink(u8* path);
        private extern "libc.so.6" i32 rmdir(u8* path);
        private extern "libc.so.6" i32 rename(u8* old, u8* nw);
        private extern "libc.so.6" void* opendir(u8* path);
        private extern "libc.so.6" u8* readdir(void* dp);
        private extern "libc.so.6" i32 closedir(void* dp);
        // struct dirent (Linux): d_name (NUL-terminated) at offset 19.
        private u8* dirent_name(u8* de) { return de + 19; }
    }
    private bool fs_mkdir1(u8* p) { return mkdir(p, 511) == 0; }   // 0o777
    private bool fs_rmdir1(u8* p) { return rmdir(p) == 0; }
    private bool fs_unlink1(u8* p) { return unlink(p) == 0; }
    private bool fs_rename1(u8* a, u8* b) { return rename(a, b) == 0; }
    // opendir succeeds only for directories — layout-free type check
    private bool fs_is_dir(u8* p) {
        void* d = opendir(p);
        if d == null { return false; }
        ignore closedir(d);
        return true;
    }
    // ns since Unix epoch -> ms
    private f64 fs_mtime_ms(u64 mt) { return cast(f64, cast(i64, mt)) / 1000000.0; }
    private void fs_readdir_into(VM* vm, str dir, JsObject* arr) {
        u8* cdir = str_to_cstr(dir);
        void* dp = opendir(cdir);
        free(cdir);
        if dp == null { return; }
        i32 idx = 0;
        while true {
            u8* de = readdir(dp);
            if de == null { break; }
            str name = str_from_cstr(dirent_name(de));
            bool dot = (name.len == 1 && *(name.data) == '.')
                || (name.len == 2 && *(name.data) == '.' && *(name.data + 1) == '.');
            if !dot { js_array_set(arr, idx, new_str(vm, name)); idx++; }
        }
        ignore closedir(dp);
    }
}
else {
    // No arm for this target. Add a `when os(...)` arm above rather
    // than letting it fall back to another platform's syscalls.
    tsmc_unsupported_target__add_a_when_os_arm _unsupported_fs;
}

private void fs_throw(VM* vm, str op, str path) {
    str_buf m;
    str_buf_init(&m);
    str_buf_add(&m, "ENOENT: no such file or directory, ");
    str_buf_add(&m, op);
    str_buf_add(&m, " '");
    str_buf_add(&m, path);
    str_buf_add(&m, "'");
    Value err = vm_make_error(vm, ERR_ERROR, str_buf_to_str(&m));
    str_buf_free(&m);
    vm_push(vm, err);
    GcString* cs = gc_new_string(&vm.heap, "ENOENT");
    js_set_prop(value_as_object(err), atom_intern(&vm.atoms, "code"), value_cell(&cs.head));
    vm_pop(vm);
    vm_throw(vm, err);
}

// Encoding from a string arg or a `{ encoding }` options object; -1 = raw
// bytes (return a Buffer).
private i32 fs_enc_arg(VM* vm, Value v) {
    if value_is_string(v) { return buf_parse_enc(v, ENC_UTF8); }
    if value_is_object(v) {
        Value ev;
        if vm_get_prop_value(vm, v, bi_atom(vm, "encoding"), &ev) && value_is_string(ev) {
            return buf_parse_enc(ev, ENC_UTF8);
        }
    }
    return -1;
}

private Value nat_fs_read_file(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    str path = path_arg(vm, args, argc, 0);
    FileData fd = file_read(path);
    if fd.data == null {
        fs_throw(vm, "open", path);
        vm_pop(vm);
        return value_undefined();
    }
    i32 enc = fs_enc_arg(vm, arg_at(args, argc, 1));
    JsObject* b = value_as_object(buf_from_bytes(vm, fd.data, fd.len));
    free(fd.data);
    Value r;
    if enc >= 0 { r = bytes_to_str(vm, b, enc, 0, b.elen); }
    else { r = value_cell(&b.head); }
    vm_pop(vm);
    return r;
}

// Fills `out` with the bytes of a string/Buffer `data` under `enc`.
private void fs_data_bytes(VM* vm, str_buf* out, Value data, i32 enc) {
    if value_is_array(data) {
        JsObject* b = value_as_object(data);
        for i32 i = 0; i < b.elen; i++ { str_buf_add_byte(out, cast(u8, buf_byte(b, i))); }
    } else {
        Value s = js_to_string_value(vm, data);
        vm_push(vm, s);
        str_to_bytes(out, sview(s), enc);
        vm_pop(vm);
    }
}

private Value nat_fs_write_file(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    str path = path_arg(vm, args, argc, 0);
    i32 enc = buf_parse_enc(arg_at(args, argc, 2), ENC_UTF8);
    str_buf bytes;
    str_buf_init(&bytes);
    fs_data_bytes(vm, &bytes, arg_at(args, argc, 1), enc);
    FileData fd;
    fd.data = bytes.data;
    fd.len = bytes.len;
    bool ok = file_write(path, fd);
    str_buf_free(&bytes);
    if !ok { fs_throw(vm, "open", path); }
    vm_pop(vm);
    return value_undefined();
}

private Value nat_fs_append_file(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    str path = path_arg(vm, args, argc, 0);
    i32 enc = buf_parse_enc(arg_at(args, argc, 2), ENC_UTF8);
    str_buf bytes;
    str_buf_init(&bytes);
    FileData old = file_read(path);
    if old.data != null {
        str_buf_add_bytes(&bytes, old.data, old.len);
        free(old.data);
    }
    fs_data_bytes(vm, &bytes, arg_at(args, argc, 1), enc);
    FileData fd;
    fd.data = bytes.data;
    fd.len = bytes.len;
    bool ok = file_write(path, fd);
    str_buf_free(&bytes);
    if !ok { fs_throw(vm, "open", path); }
    vm_pop(vm);
    return value_undefined();
}

// See fs_exists1's wasm arm: the file_exists builtin is unusable there.
when os(wasm) {
    private bool fs_exists1(str path) {
        u8* c = str_to_cstr(path);
        i64 fd = open(c, 0);
        free(c);
        if fd == cast(i64, 0) - 1 { return false; }
        close(fd);
        return true;
    }
}
else {
    private bool fs_exists1(str path) { return file_exists(path); }
}

private Value nat_fs_exists(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    str path = path_arg(vm, args, argc, 0);
    bool ok = fs_exists1(path);
    vm_pop(vm);
    return value_bool(ok);
}

private Value nat_fs_unlink(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    str path = path_arg(vm, args, argc, 0);
    u8* c = str_to_cstr(path);
    bool ok = fs_unlink1(c);
    free(c);
    if !ok { fs_throw(vm, "unlink", path); }
    vm_pop(vm);
    return value_undefined();
}

private Value nat_fs_rename(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    str src = path_arg(vm, args, argc, 0);
    str dst = path_arg(vm, args, argc, 1);
    u8* cf = str_to_cstr(src);
    u8* ct = str_to_cstr(dst);
    bool ok = fs_rename1(cf, ct);
    free(cf);
    free(ct);
    if !ok { fs_throw(vm, "rename", src); }
    vm_pop(vm);   // dst
    vm_pop(vm);   // src
    return value_undefined();
}

private Value nat_fs_mkdir(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    str path = path_arg(vm, args, argc, 0);
    bool recursive = false;
    Value opts = arg_at(args, argc, 1);
    if value_is_object(opts) {
        Value rv;
        if vm_get_prop_value(vm, opts, bi_atom(vm, "recursive"), &rv) { recursive = js_truthy(rv); }
    }
    if recursive {
        // create each ancestor in turn; ignore already-exists failures
        for i32 i = 1; i <= path.len; i++ {
            bool at_end = i == path.len;
            if at_end || path_is_sep(*(path.data + i)) {
                if i == 0 { continue; }
                str pre;
                pre.data = path.data;
                pre.len = i;
                u8* c = str_to_cstr(pre);
                ignore fs_mkdir1(c);
                free(c);
            }
        }
    } else {
        u8* c = str_to_cstr(path);
        ignore fs_mkdir1(c);
        free(c);
    }
    vm_pop(vm);
    return value_undefined();
}

private Value nat_fs_readdir(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    str path = path_arg(vm, args, argc, 0);
    JsObject* arr = js_new_array(&vm.heap, vm.array_proto);
    vm_push(vm, value_cell(&arr.head));
    fs_readdir_into(vm, path, arr);
    Value r = value_cell(&arr.head);
    vm_pop(vm);   // arr
    vm_pop(vm);   // path
    return r;
}

private Value nat_fs_rmdir(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    str path = path_arg(vm, args, argc, 0);
    u8* c = str_to_cstr(path);
    bool ok = fs_rmdir1(c);
    free(c);
    if !ok { fs_throw(vm, "rmdir", path); }
    vm_pop(vm);
    return value_undefined();
}

private Value nat_fs_stat_isfile(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    Value d;
    if vm_get_prop_value(as_vm(vmp), thisv, bi_atom(as_vm(vmp), "isDirectory_"), &d) {
        return value_bool(!js_truthy(d));
    }
    return value_bool(true);
}
private Value nat_fs_stat_isdir(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    Value d;
    if vm_get_prop_value(as_vm(vmp), thisv, bi_atom(as_vm(vmp), "isDirectory_"), &d) {
        return value_bool(js_truthy(d));
    }
    return value_bool(false);
}

private Value nat_fs_stat(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    str path = path_arg(vm, args, argc, 0);
    FileStamp st = file_stamp(path);
    if !st.ok {
        fs_throw(vm, "stat", path);
        vm_pop(vm);
        return value_undefined();
    }
    u8* c = str_to_cstr(path);
    bool isdir = fs_is_dir(c);
    free(c);
    vm_pop(vm);
    JsObject* o = js_new_object(&vm.heap, vm.object_proto);
    vm_push(vm, value_cell(&o.head));
    def_value_enum(vm, o, "size", value_number(cast(f64, st.size)));
    def_value_enum(vm, o, "mtimeMs", value_number(fs_mtime_ms(st.mtime)));
    props_set_desc(&o.props, bi_atom(vm, "isDirectory_"), value_bool(isdir), 0);  // hidden flag
    def_method(vm, o, "isFile", &nat_fs_stat_isfile);
    def_method(vm, o, "isDirectory", &nat_fs_stat_isdir);
    Value r = value_cell(&o.head);
    vm_pop(vm);
    return r;
}

// --- fs async: promise + callback wrappers over the sync cores ---
//
// Each sync native returns a result and sets vm.has_pending on throw. The
// async wrappers run the sync core, then turn its result / pending error
// into a settled Promise (fs.promises) or a scheduled (err, value)
// callback (fs.readFile etc.).

private Value fs_promise_of(VM* vm, Value r) {
    i32 rm = gc_root_mark(&vm.heap);
    gc_root(&vm.heap, r);
    Value p = vm_promise_new(vm);
    gc_root(&vm.heap, p);
    if vm.has_pending {
        Value err = vm.pending;
        vm.has_pending = false;
        vm.pending = value_undefined();
        gc_root(&vm.heap, err);
        vm_promise_settle(vm, p, err, true);
    } else {
        vm_promise_settle(vm, p, r, false);
    }
    gc_root_reset(&vm.heap, rm);
    return p;
}

// Runs a sync fs native over `args` and wraps the outcome in a Promise.
private Value fs_promise_run(VM* vm, NativeFn sync, Value callee, Value* args, i32 argc) {
    Value r = sync(cast(void*, vm), callee, value_undefined(), args, argc);
    return fs_promise_of(vm, r);
}

// Invokes cb(err, value) later (env0 = cb, env1 = err, env2 = value).
private Value nat_fs_cb_invoke(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    JsNative* me = value_as_native(callee);
    Value[2] a;
    a[0] = me.env1;
    a[1] = me.env2;
    ignore vm_call_value(vm, me.env0, value_undefined(), &a[0], 2);
    return value_undefined();
}

// Schedules cb(err, value) as a microtask (fs callbacks are asynchronous).
private void fs_schedule_cb(VM* vm, Value cb, Value err, Value value) {
    i32 rm = gc_root_mark(&vm.heap);
    gc_root(&vm.heap, cb);
    gc_root(&vm.heap, err);
    gc_root(&vm.heap, value);
    JsNative* inv = js_new_native(&vm.heap, &nat_fs_cb_invoke, "");
    inv.env0 = cb;
    inv.env1 = err;
    inv.env2 = value;
    gc_root(&vm.heap, value_cell(&inv.head));
    Value p = vm_promise_new(vm);
    gc_root(&vm.heap, p);
    vm_promise_settle(vm, p, value_undefined(), false);
    ignore vm_promise_then(vm, p, value_cell(&inv.head), value_undefined());
    gc_root_reset(&vm.heap, rm);
}

// Runs a sync fs native over (args minus the trailing callback), then
// schedules cb(err, result).
private Value fs_cb_run(VM* vm, NativeFn sync, Value callee, Value* args, i32 argc) {
    if argc == 0 { return value_undefined(); }
    Value cb = *(args + argc - 1);
    Value r = sync(cast(void*, vm), callee, value_undefined(), args, argc - 1);
    Value err = value_null();
    Value val = r;
    if vm.has_pending {
        err = vm.pending;
        vm.has_pending = false;
        vm.pending = value_undefined();
        val = value_undefined();
    }
    if value_is_callable(cb) { fs_schedule_cb(vm, cb, err, val); }
    return value_undefined();
}

private Value nat_fsp_read_file(void* vmp, Value callee, Value thisv, Value* args, i32 argc) { return fs_promise_run(as_vm(vmp), &nat_fs_read_file, callee, args, argc); }
private Value nat_fsp_write_file(void* vmp, Value callee, Value thisv, Value* args, i32 argc) { return fs_promise_run(as_vm(vmp), &nat_fs_write_file, callee, args, argc); }
private Value nat_fsp_append_file(void* vmp, Value callee, Value thisv, Value* args, i32 argc) { return fs_promise_run(as_vm(vmp), &nat_fs_append_file, callee, args, argc); }
private Value nat_fsp_mkdir(void* vmp, Value callee, Value thisv, Value* args, i32 argc) { return fs_promise_run(as_vm(vmp), &nat_fs_mkdir, callee, args, argc); }
private Value nat_fsp_readdir(void* vmp, Value callee, Value thisv, Value* args, i32 argc) { return fs_promise_run(as_vm(vmp), &nat_fs_readdir, callee, args, argc); }
private Value nat_fsp_rmdir(void* vmp, Value callee, Value thisv, Value* args, i32 argc) { return fs_promise_run(as_vm(vmp), &nat_fs_rmdir, callee, args, argc); }
private Value nat_fsp_unlink(void* vmp, Value callee, Value thisv, Value* args, i32 argc) { return fs_promise_run(as_vm(vmp), &nat_fs_unlink, callee, args, argc); }
private Value nat_fsp_rename(void* vmp, Value callee, Value thisv, Value* args, i32 argc) { return fs_promise_run(as_vm(vmp), &nat_fs_rename, callee, args, argc); }
private Value nat_fsp_stat(void* vmp, Value callee, Value thisv, Value* args, i32 argc) { return fs_promise_run(as_vm(vmp), &nat_fs_stat, callee, args, argc); }

private Value nat_fscb_read_file(void* vmp, Value callee, Value thisv, Value* args, i32 argc) { return fs_cb_run(as_vm(vmp), &nat_fs_read_file, callee, args, argc); }
private Value nat_fscb_write_file(void* vmp, Value callee, Value thisv, Value* args, i32 argc) { return fs_cb_run(as_vm(vmp), &nat_fs_write_file, callee, args, argc); }
private Value nat_fscb_append_file(void* vmp, Value callee, Value thisv, Value* args, i32 argc) { return fs_cb_run(as_vm(vmp), &nat_fs_append_file, callee, args, argc); }
private Value nat_fscb_mkdir(void* vmp, Value callee, Value thisv, Value* args, i32 argc) { return fs_cb_run(as_vm(vmp), &nat_fs_mkdir, callee, args, argc); }
private Value nat_fscb_readdir(void* vmp, Value callee, Value thisv, Value* args, i32 argc) { return fs_cb_run(as_vm(vmp), &nat_fs_readdir, callee, args, argc); }
private Value nat_fscb_rmdir(void* vmp, Value callee, Value thisv, Value* args, i32 argc) { return fs_cb_run(as_vm(vmp), &nat_fs_rmdir, callee, args, argc); }
private Value nat_fscb_unlink(void* vmp, Value callee, Value thisv, Value* args, i32 argc) { return fs_cb_run(as_vm(vmp), &nat_fs_unlink, callee, args, argc); }
private Value nat_fscb_rename(void* vmp, Value callee, Value thisv, Value* args, i32 argc) { return fs_cb_run(as_vm(vmp), &nat_fs_rename, callee, args, argc); }
private Value nat_fscb_stat(void* vmp, Value callee, Value thisv, Value* args, i32 argc) { return fs_cb_run(as_vm(vmp), &nat_fs_stat, callee, args, argc); }

private Value get_prop_or_undef(VM* vm, JsObject* o, str name) {
    Value v;
    if js_get_prop(o, bi_atom(vm, name), &v) { return v; }
    return value_undefined();
}

// The fs.promises object (also the `fs/promises` module's default).
private JsObject* build_fs_promises(VM* vm) {
    JsObject* pr = js_new_object(&vm.heap, vm.object_proto);
    def_method(vm, pr, "readFile", &nat_fsp_read_file);
    def_method(vm, pr, "writeFile", &nat_fsp_write_file);
    def_method(vm, pr, "appendFile", &nat_fsp_append_file);
    def_method(vm, pr, "mkdir", &nat_fsp_mkdir);
    def_method(vm, pr, "readdir", &nat_fsp_readdir);
    def_method(vm, pr, "rmdir", &nat_fsp_rmdir);
    def_method(vm, pr, "unlink", &nat_fsp_unlink);
    def_method(vm, pr, "rename", &nat_fsp_rename);
    def_method(vm, pr, "stat", &nat_fsp_stat);
    return pr;
}

// Namespace for `require('fs/promises')` / `import ... from 'fs/promises'`.
JsObject* builtins_fs_promises_module(VM* vm) {
    if vm.node_fsp_ns != null { return vm.node_fsp_ns; }
    JsObject* ns = js_new_object(&vm.heap, null);
    gc_root(&vm.heap, value_cell(&ns.head));
    vm.node_fsp_ns = ns;
    JsObject* pr = build_fs_promises(vm);
    props_set_desc(&ns.props, bi_atom(vm, "default"), value_cell(&pr.head), PROP_DEFAULT);
    // mirror each promise method as a named export
    props_set_desc(&ns.props, bi_atom(vm, "readFile"), get_prop_or_undef(vm, pr, "readFile"), PROP_DEFAULT);
    props_set_desc(&ns.props, bi_atom(vm, "writeFile"), get_prop_or_undef(vm, pr, "writeFile"), PROP_DEFAULT);
    props_set_desc(&ns.props, bi_atom(vm, "appendFile"), get_prop_or_undef(vm, pr, "appendFile"), PROP_DEFAULT);
    props_set_desc(&ns.props, bi_atom(vm, "mkdir"), get_prop_or_undef(vm, pr, "mkdir"), PROP_DEFAULT);
    props_set_desc(&ns.props, bi_atom(vm, "readdir"), get_prop_or_undef(vm, pr, "readdir"), PROP_DEFAULT);
    props_set_desc(&ns.props, bi_atom(vm, "rmdir"), get_prop_or_undef(vm, pr, "rmdir"), PROP_DEFAULT);
    props_set_desc(&ns.props, bi_atom(vm, "unlink"), get_prop_or_undef(vm, pr, "unlink"), PROP_DEFAULT);
    props_set_desc(&ns.props, bi_atom(vm, "rename"), get_prop_or_undef(vm, pr, "rename"), PROP_DEFAULT);
    props_set_desc(&ns.props, bi_atom(vm, "stat"), get_prop_or_undef(vm, pr, "stat"), PROP_DEFAULT);
    return ns;
}

private JsObject* build_fs_module(VM* vm) {
    JsObject* mod;
    JsObject* ns = new_node_module(vm, &mod);
    def_node_export(vm, mod, ns, "readFileSync", &nat_fs_read_file);
    def_node_export(vm, mod, ns, "writeFileSync", &nat_fs_write_file);
    def_node_export(vm, mod, ns, "appendFileSync", &nat_fs_append_file);
    def_node_export(vm, mod, ns, "existsSync", &nat_fs_exists);
    def_node_export(vm, mod, ns, "mkdirSync", &nat_fs_mkdir);
    def_node_export(vm, mod, ns, "readdirSync", &nat_fs_readdir);
    def_node_export(vm, mod, ns, "rmdirSync", &nat_fs_rmdir);
    def_node_export(vm, mod, ns, "unlinkSync", &nat_fs_unlink);
    def_node_export(vm, mod, ns, "renameSync", &nat_fs_rename);
    def_node_export(vm, mod, ns, "statSync", &nat_fs_stat);
    // callback (async) API
    def_node_export(vm, mod, ns, "readFile", &nat_fscb_read_file);
    def_node_export(vm, mod, ns, "writeFile", &nat_fscb_write_file);
    def_node_export(vm, mod, ns, "appendFile", &nat_fscb_append_file);
    def_node_export(vm, mod, ns, "mkdir", &nat_fscb_mkdir);
    def_node_export(vm, mod, ns, "readdir", &nat_fscb_readdir);
    def_node_export(vm, mod, ns, "rmdir", &nat_fscb_rmdir);
    def_node_export(vm, mod, ns, "unlink", &nat_fscb_unlink);
    def_node_export(vm, mod, ns, "rename", &nat_fscb_rename);
    def_node_export(vm, mod, ns, "stat", &nat_fscb_stat);
    // fs.promises
    JsObject* pr = build_fs_promises(vm);
    def_node_value(vm, mod, ns, "promises", value_cell(&pr.head));
    return ns;
}

private JsObject* build_path_module(VM* vm) {
    JsObject* mod;
    JsObject* ns = new_node_module(vm, &mod);
    def_node_export(vm, mod, ns, "join", &nat_path_join);
    def_node_export(vm, mod, ns, "resolve", &nat_path_resolve);
    def_node_export(vm, mod, ns, "normalize", &nat_path_normalize);
    def_node_export(vm, mod, ns, "dirname", &nat_path_dirname);
    def_node_export(vm, mod, ns, "basename", &nat_path_basename);
    def_node_export(vm, mod, ns, "extname", &nat_path_extname);
    def_node_export(vm, mod, ns, "isAbsolute", &nat_path_isabsolute);
    def_node_export(vm, mod, ns, "parse", &nat_path_parse);
    def_node_value(vm, mod, ns, "sep", new_str(vm, path_sep_str()));
    def_node_value(vm, mod, ns, "delimiter", new_str(vm, path_delim_str()));
    return ns;
}

// --- os: OS layer -----------------------------------------------------------

when os(windows) {
    private extern "msvcrt.dll" u8* getenv(u8* name);
    private extern "kernel32.dll" i32 GetComputerNameA(u8* buf, u32* size);
    struct _SysInfo {
        u16 arch; u16 res; u32 pagesize;
        void* minaddr; void* maxaddr; u64 mask;
        u32 ncpu; u32 proctype; u32 alloc; u16 level; u16 rev;
    }
    private extern "kernel32.dll" void GetSystemInfo(_SysInfo* si);
    private str os_type_str() { return "Windows_NT"; }
    private str os_eol_str() { return "\r\n"; }
    private i32 os_ncpu() { _SysInfo si; GetSystemInfo(&si); return cast(i32, si.ncpu); }
    private bool os_hostname_into(u8* buf, i32 cap) {
        u32 sz = cast(u32, cap);
        return GetComputerNameA(buf, &sz) != 0;
    }
    private u8* os_home() { u8* h = getenv("USERPROFILE"); return h; }
    private u8* os_tmp() { u8* t = getenv("TEMP"); if t == null { t = getenv("TMP"); } return t; }
    private u8* os_user() { return getenv("USERNAME"); }
    private u8* os_shell() { return null; }
    private i32 os_uid() { return 0 - 1; }
    private i32 os_gid() { return 0 - 1; }
}
else when os(wasm) {
    // Sandbox: no environment, no host identity. os.* reports the
    // neutral values the accessors already use for "unknown".
    private str os_type_str() { return "Wasm"; }
    private str os_eol_str() { return "\n"; }
    private i32 os_ncpu() { return 1; }
    private bool os_hostname_into(u8* buf, i32 cap) { return false; }
    private u8* os_home() { return null; }
    private u8* os_tmp() { return null; }
    private u8* os_user() { return null; }
    private u8* os_shell() { return null; }
    private i32 os_uid() { return 0 - 1; }
    private i32 os_gid() { return 0 - 1; }
}
else when os(macos) || os(ios) || os(linux) || os(android) {
    when os(macos) || os(ios) {
        private extern "libSystem.B.dylib" u8* getenv(u8* name);
        private extern "libSystem.B.dylib" i32 gethostname(u8* buf, u64 len);
        private extern "libSystem.B.dylib" i64 sysconf(i32 name);
        private extern "libSystem.B.dylib" i32 getuid();
        private extern "libSystem.B.dylib" i32 getgid();
        private str os_type_str() { return "Darwin"; }
        private i32 os_ncpu_name() { return 58; }   // _SC_NPROCESSORS_ONLN (Darwin)
    }
    else when os(android) {
        private extern "libc.so" u8* getenv(u8* name);
        private extern "libc.so" i32 gethostname(u8* buf, u64 len);
        private extern "libc.so" i64 sysconf(i32 name);
        private extern "libc.so" i32 getuid();
        private extern "libc.so" i32 getgid();
        private str os_type_str() { return "Linux"; }
        private i32 os_ncpu_name() { return 84; }   // _SC_NPROCESSORS_ONLN (Linux)
    }
    else {
        private extern "libc.so.6" u8* getenv(u8* name);
        private extern "libc.so.6" i32 gethostname(u8* buf, u64 len);
        private extern "libc.so.6" i64 sysconf(i32 name);
        private extern "libc.so.6" i32 getuid();
        private extern "libc.so.6" i32 getgid();
        private str os_type_str() { return "Linux"; }
        private i32 os_ncpu_name() { return 84; }   // _SC_NPROCESSORS_ONLN (Linux)
    }
    private str os_eol_str() { return "\n"; }
    private i32 os_ncpu() { i64 n = sysconf(os_ncpu_name()); if n < 1 { return 1; } return cast(i32, n); }
    private bool os_hostname_into(u8* buf, i32 cap) { return gethostname(buf, cast(u64, cap)) == 0; }
    private u8* os_home() { return getenv("HOME"); }
    private u8* os_tmp() { return getenv("TMPDIR"); }
    private u8* os_user() { return getenv("USER"); }
    private u8* os_shell() { return getenv("SHELL"); }
    private i32 os_uid() { return getuid(); }
    private i32 os_gid() { return getgid(); }
}
else {
    // No arm for this target. Add a `when os(...)` arm above rather
    // than letting it fall back to another platform's syscalls.
    tsmc_unsupported_target__add_a_when_os_arm _unsupported_os;
}

private Value os_cstr_or_empty(VM* vm, u8* c) {
    if c == null { return new_str(vm, ""); }
    return new_str(vm, str_from_cstr(c));
}

private Value nat_os_platform(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    return new_str(as_vm(vmp), os_platform_name());
}
private Value nat_os_arch(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    return new_str(as_vm(vmp), os_arch_name());
}
private Value nat_os_type(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    return new_str(as_vm(vmp), os_type_str());
}
private Value nat_os_endianness(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    return new_str(as_vm(vmp), "LE");
}
private Value nat_os_homedir(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    return os_cstr_or_empty(as_vm(vmp), os_home());
}
private Value nat_os_tmpdir(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    u8* t = os_tmp();
    when os(windows) { if t == null { t = cast(u8*, str_to_cstr(".")); } }
    str s;
    if t == null { s = "/tmp"; } else { s = str_from_cstr(t); }
    i32 end = s.len;   // Node trims a trailing separator (except a bare root)
    while end > 1 && path_is_sep(*(s.data + end - 1)) { end--; }
    s.len = end;
    return new_str(vm, s);
}
private Value nat_os_hostname(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    u8[256] buf;
    if os_hostname_into(&buf[0], 256) { return new_str(vm, str_from_cstr(&buf[0])); }
    return new_str(vm, "");
}
private Value nat_os_cpus(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    i32 n = os_ncpu();
    JsObject* arr = js_new_array(&vm.heap, vm.array_proto);
    vm_push(vm, value_cell(&arr.head));
    for i32 i = 0; i < n; i++ {
        JsObject* cpu = js_new_object(&vm.heap, vm.object_proto);
        js_array_set(arr, i, value_cell(&cpu.head));
        def_value_enum(vm, cpu, "model", new_str(vm, "unknown"));
        def_value_enum(vm, cpu, "speed", value_number(0.0));
        JsObject* times = js_new_object(&vm.heap, vm.object_proto);
        def_value_enum(vm, cpu, "times", value_cell(&times.head));
        def_value_enum(vm, times, "user", value_number(0.0));
        def_value_enum(vm, times, "nice", value_number(0.0));
        def_value_enum(vm, times, "sys", value_number(0.0));
        def_value_enum(vm, times, "idle", value_number(0.0));
        def_value_enum(vm, times, "irq", value_number(0.0));
    }
    Value r = value_cell(&arr.head);
    vm_pop(vm);
    return r;
}
private Value nat_os_userinfo(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    JsObject* o = js_new_object(&vm.heap, vm.object_proto);
    vm_push(vm, value_cell(&o.head));
    def_value_enum(vm, o, "username", os_cstr_or_empty(vm, os_user()));
    def_value_enum(vm, o, "homedir", os_cstr_or_empty(vm, os_home()));
    def_value_enum(vm, o, "uid", value_number(cast(f64, os_uid())));
    def_value_enum(vm, o, "gid", value_number(cast(f64, os_gid())));
    u8* sh = os_shell();
    def_value_enum(vm, o, "shell", sh == null ? value_null() : new_str(vm, str_from_cstr(sh)));
    Value r = value_cell(&o.head);
    vm_pop(vm);
    return r;
}

private JsObject* build_os_module(VM* vm) {
    JsObject* mod;
    JsObject* ns = new_node_module(vm, &mod);
    def_node_export(vm, mod, ns, "platform", &nat_os_platform);
    def_node_export(vm, mod, ns, "arch", &nat_os_arch);
    def_node_export(vm, mod, ns, "type", &nat_os_type);
    def_node_export(vm, mod, ns, "endianness", &nat_os_endianness);
    def_node_export(vm, mod, ns, "homedir", &nat_os_homedir);
    def_node_export(vm, mod, ns, "tmpdir", &nat_os_tmpdir);
    def_node_export(vm, mod, ns, "hostname", &nat_os_hostname);
    def_node_export(vm, mod, ns, "cpus", &nat_os_cpus);
    def_node_export(vm, mod, ns, "userInfo", &nat_os_userinfo);
    def_node_value(vm, mod, ns, "EOL", new_str(vm, os_eol_str()));
    return ns;
}

// --- events / EventEmitter --------------------------------------------------
//
// Per-instance state is a hidden `%events` object mapping each event name
// (string) to an ordered listener array. `once` listeners are stored as a
// self-removing wrapper native that carries the original in env2.

private bool ee_is_once_wrapper(Value v) {
    return value_is_native(v) && value_as_native(v).fun == &nat_ee_once_wrap;
}

// The original function behind a listener (a once-wrapper unwraps to its
// stored original; a plain listener is itself).
private Value ee_unwrap(Value v) {
    if ee_is_once_wrapper(v) { return value_as_native(v).env2; }
    return v;
}

private JsObject* ee_events(VM* vm, Value thisv, bool create) {
    if !value_is_object(thisv) { return null; }
    JsObject* self = value_as_object(thisv);
    Value ev;
    if js_get_prop(self, bi_atom(vm, "%events"), &ev) && value_is_object(ev) {
        return value_as_object(ev);
    }
    if !create { return null; }
    JsObject* e = js_new_object(&vm.heap, null);
    props_set_desc(&self.props, bi_atom(vm, "%events"), value_cell(&e.head), 0);
    return e;
}

private JsObject* ee_list(VM* vm, JsObject* events, str name, bool create) {
    u32 atom = atom_intern(&vm.atoms, name);
    Value a;
    if js_get_prop(events, atom, &a) && value_is_array(a) { return value_as_object(a); }
    if !create { return null; }
    JsObject* arr = js_new_array(&vm.heap, vm.array_proto);
    props_set_desc(&events.props, atom, value_cell(&arr.head), PROP_DEFAULT);
    return arr;
}

// Removes the first listener that is `target` or a once-wrapper whose
// original is `target`; compacts in place. Returns true if one was removed.
private bool ee_remove_match(JsObject* list, Value target) {
    for i32 i = 0; i < list.elen; i++ {
        Value e = js_array_get(list, i);
        if value_same_bits(e, target) || value_same_bits(ee_unwrap(e), target) {
            for i32 j = i; j < list.elen - 1; j++ { js_array_set(list, j, js_array_get(list, j + 1)); }
            js_array_set_length(list, list.elen - 1);
            return true;
        }
    }
    return false;
}

// Adds `fn` to the listener array for arg[0]'s event; front-inserts when
// `prepend`. Shared by on/prependListener (and the once variants via `fn`
// being a wrapper).
private Value ee_add(VM* vm, Value thisv, Value* args, i32 argc, Value cb, bool prepend) {
    Value namev = js_to_string_value(vm, arg_at(args, argc, 0));
    vm_push(vm, namev);
    vm_push(vm, cb);
    JsObject* events = ee_events(vm, thisv, true);
    JsObject* list = ee_list(vm, events, sview(namev), true);
    if prepend {
        for i32 i = list.elen; i > 0; i-- { js_array_set(list, i, js_array_get(list, i - 1)); }
        js_array_set(list, 0, cb);
    } else {
        js_array_set(list, list.elen, cb);
    }
    vm_pop(vm);
    vm_pop(vm);
    return thisv;
}

private Value nat_ee_ctor(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    // state is lazy; `new` supplies the instance as thisv (returning a
    // non-reference keeps it — see OP_NEW). Nothing to initialize here.
    return value_undefined();
}

private Value nat_ee_on(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    Value cb = arg_at(args, argc, 1);
    if !value_is_callable(cb) {
        vm_throw_error(vm, ERR_TYPE, "listener must be a function");
        return value_undefined();
    }
    return ee_add(vm, thisv, args, argc, cb, false);
}

private Value nat_ee_prepend(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    Value cb = arg_at(args, argc, 1);
    if !value_is_callable(cb) {
        vm_throw_error(vm, ERR_TYPE, "listener must be a function");
        return value_undefined();
    }
    return ee_add(vm, thisv, args, argc, cb, true);
}

// Builds a once-wrapper native carrying (emitter, event name, original cb).
private Value ee_make_once(VM* vm, Value thisv, Value namev, Value cb) {
    vm_push(vm, namev);
    vm_push(vm, cb);
    JsNative* w = js_new_native(&vm.heap, &nat_ee_once_wrap, "");
    w.env0 = thisv;
    w.env1 = namev;
    w.env2 = cb;
    vm_pop(vm);
    vm_pop(vm);
    return value_cell(&w.head);
}

private Value nat_ee_once(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    Value cb = arg_at(args, argc, 1);
    if !value_is_callable(cb) {
        vm_throw_error(vm, ERR_TYPE, "listener must be a function");
        return value_undefined();
    }
    Value namev = js_to_string_value(vm, arg_at(args, argc, 0));
    vm_push(vm, namev);
    Value w = ee_make_once(vm, thisv, namev, cb);
    vm_push(vm, w);
    Value r = ee_add(vm, thisv, args, argc, w, false);
    vm_pop(vm);
    vm_pop(vm);
    return r;
}

private Value nat_ee_prepend_once(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    Value cb = arg_at(args, argc, 1);
    if !value_is_callable(cb) {
        vm_throw_error(vm, ERR_TYPE, "listener must be a function");
        return value_undefined();
    }
    Value namev = js_to_string_value(vm, arg_at(args, argc, 0));
    vm_push(vm, namev);
    Value w = ee_make_once(vm, thisv, namev, cb);
    vm_push(vm, w);
    Value r = ee_add(vm, thisv, args, argc, w, true);
    vm_pop(vm);
    vm_pop(vm);
    return r;
}

private Value nat_ee_once_wrap(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    JsNative* w = value_as_native(callee);
    Value emitter = w.env0;
    Value cb = w.env2;
    // detach this wrapper before firing (fires exactly once)
    JsObject* events = ee_events(vm, emitter, false);
    if events != null {
        JsObject* list = ee_list(vm, events, sview(w.env1), false);
        if list != null { ignore ee_remove_match(list, callee); }
    }
    return vm_call_value(vm, cb, thisv, args, argc);
}

private Value nat_ee_off(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    Value cb = arg_at(args, argc, 1);
    Value namev = js_to_string_value(vm, arg_at(args, argc, 0));
    vm_push(vm, namev);
    JsObject* events = ee_events(vm, thisv, false);
    if events != null {
        JsObject* list = ee_list(vm, events, sview(namev), false);
        if list != null { ignore ee_remove_match(list, cb); }
    }
    vm_pop(vm);
    return thisv;
}

private Value nat_ee_emit(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    Value namev = js_to_string_value(vm, arg_at(args, argc, 0));
    vm_push(vm, namev);
    JsObject* events = ee_events(vm, thisv, false);
    JsObject* list = events != null ? ee_list(vm, events, sview(namev), false) : null;
    if list == null || list.elen == 0 {
        bool is_error = str_equal(sview(namev), "error");
        vm_pop(vm);
        if is_error {
            Value errv = arg_at(args, argc, 1);
            if value_is_object(errv) { vm_throw(vm, errv); }
            else { vm_throw_error(vm, ERR_ERROR, "Unhandled 'error' event"); }
            return value_undefined();
        }
        return value_bool(false);
    }
    // snapshot: a listener (e.g. a once wrapper) may mutate the list
    i32 n = list.elen;
    JsObject* snap = js_new_array(&vm.heap, vm.array_proto);
    vm_push(vm, value_cell(&snap.head));
    for i32 i = 0; i < n; i++ { js_array_set(snap, i, js_array_get(list, i)); }
    i32 nargs = argc > 1 ? argc - 1 : 0;
    for i32 i = 0; i < n; i++ {
        Value lf = js_array_get(snap, i);
        ignore vm_call_value(vm, lf, thisv, args + 1, nargs);
        if vm.has_pending { break; }
    }
    vm_pop(vm);
    vm_pop(vm);
    return value_bool(true);
}

private Value nat_ee_listeners_impl(VM* vm, Value thisv, Value* args, i32 argc, bool raw) {
    Value namev = js_to_string_value(vm, arg_at(args, argc, 0));
    vm_push(vm, namev);
    JsObject* out = js_new_array(&vm.heap, vm.array_proto);
    vm_push(vm, value_cell(&out.head));
    JsObject* events = ee_events(vm, thisv, false);
    JsObject* list = events != null ? ee_list(vm, events, sview(namev), false) : null;
    if list != null {
        for i32 i = 0; i < list.elen; i++ {
            Value e = js_array_get(list, i);
            js_array_set(out, i, raw ? e : ee_unwrap(e));
        }
    }
    Value r = value_cell(&out.head);
    vm_pop(vm);
    vm_pop(vm);
    return r;
}

private Value nat_ee_listeners(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    return nat_ee_listeners_impl(as_vm(vmp), thisv, args, argc, false);
}
private Value nat_ee_raw_listeners(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    return nat_ee_listeners_impl(as_vm(vmp), thisv, args, argc, true);
}

private Value nat_ee_listener_count(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    Value namev = js_to_string_value(vm, arg_at(args, argc, 0));
    vm_push(vm, namev);
    JsObject* events = ee_events(vm, thisv, false);
    JsObject* list = events != null ? ee_list(vm, events, sview(namev), false) : null;
    i32 c = list != null ? list.elen : 0;
    vm_pop(vm);
    return value_number(cast(f64, c));
}

private Value nat_ee_event_names(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    JsObject* out = js_new_array(&vm.heap, vm.array_proto);
    vm_push(vm, value_cell(&out.head));
    JsObject* events = ee_events(vm, thisv, false);
    i32 n = 0;
    if events != null {
        JsObject* keys = vm_own_keys(vm, value_cell(&events.head));
        vm_push(vm, value_cell(&keys.head));
        for i32 i = 0; i < keys.elen; i++ {
            Value kv = js_array_get(keys, i);
            Value av;
            if js_get_prop(events, atom_intern(&vm.atoms, sview(kv)), &av)
                && value_is_array(av) && value_as_object(av).elen > 0 {
                js_array_set(out, n, kv);
                n++;
            }
        }
        vm_pop(vm);
    }
    Value r = value_cell(&out.head);
    vm_pop(vm);
    return r;
}

private Value nat_ee_remove_all(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    JsObject* events = ee_events(vm, thisv, false);
    if events != null {
        Value namev = arg_at(args, argc, 0);
        if value_is_undefined(namev) {
            // clear everything: replace with a fresh %events
            JsObject* self = value_as_object(thisv);
            JsObject* fresh = js_new_object(&vm.heap, null);
            props_set_desc(&self.props, bi_atom(vm, "%events"), value_cell(&fresh.head), 0);
        } else {
            Value ns = js_to_string_value(vm, namev);
            vm_push(vm, ns);
            JsObject* list = ee_list(vm, events, sview(ns), false);
            if list != null { js_array_set_length(list, 0); }
            vm_pop(vm);
        }
    }
    return thisv;
}

private Value nat_ee_set_max(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    if value_is_object(thisv) {
        js_set_prop(value_as_object(thisv), bi_atom(vm, "%maxListeners"),
            value_number(cast(f64, to_int_arg(arg_at(args, argc, 0)))));
    }
    return thisv;
}

private Value nat_ee_get_max(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    if value_is_object(thisv) {
        Value m;
        if js_get_prop(value_as_object(thisv), bi_atom(vm, "%maxListeners"), &m) && value_is_number(m) {
            return m;
        }
    }
    return value_number(10.0);
}

private JsObject* build_events_module(VM* vm) {
    JsObject* proto = js_new_object(&vm.heap, vm.object_proto);
    vm_push(vm, value_cell(&proto.head));
    JsNative* ctor = js_new_native(&vm.heap, &nat_ee_ctor, "EventEmitter");
    vm_push(vm, value_cell(&ctor.head));
    props_set_desc(&ctor.props, vm.atom_prototype, value_cell(&proto.head), 0);
    link_ctor(vm, proto, ctor);

    def_method(vm, proto, "on", &nat_ee_on);
    def_method(vm, proto, "addListener", &nat_ee_on);
    def_method(vm, proto, "once", &nat_ee_once);
    def_method(vm, proto, "off", &nat_ee_off);
    def_method(vm, proto, "removeListener", &nat_ee_off);
    def_method(vm, proto, "emit", &nat_ee_emit);
    def_method(vm, proto, "removeAllListeners", &nat_ee_remove_all);
    def_method(vm, proto, "listeners", &nat_ee_listeners);
    def_method(vm, proto, "rawListeners", &nat_ee_raw_listeners);
    def_method(vm, proto, "listenerCount", &nat_ee_listener_count);
    def_method(vm, proto, "eventNames", &nat_ee_event_names);
    def_method(vm, proto, "prependListener", &nat_ee_prepend);
    def_method(vm, proto, "prependOnceListener", &nat_ee_prepend_once);
    def_method(vm, proto, "setMaxListeners", &nat_ee_set_max);
    def_method(vm, proto, "getMaxListeners", &nat_ee_get_max);

    props_set_desc(&ctor.props, bi_atom(vm, "EventEmitter"), value_cell(&ctor.head), PROP_DEFAULT);
    props_set_desc(&ctor.props, bi_atom(vm, "defaultMaxListeners"), value_number(10.0), PROP_DEFAULT);

    // namespace: default = the EventEmitter class (require('events') is the
    // class in Node), plus a named EventEmitter export.
    JsObject* ns = js_new_object(&vm.heap, null);
    gc_root(&vm.heap, value_cell(&ns.head));
    props_set_desc(&ns.props, bi_atom(vm, "default"), value_cell(&ctor.head), PROP_DEFAULT);
    props_set_desc(&ns.props, bi_atom(vm, "EventEmitter"), value_cell(&ctor.head), PROP_DEFAULT);
    vm_pop(vm);
    vm_pop(vm);
    return ns;
}

// --- util -------------------------------------------------------------------

// promisify: the wrapper (env0 = original) builds a Promise and calls the
// original with a trailing (err, value) callback (env0 = the promise).
private Value nat_promisify_cb(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    Value p = value_as_native(callee).env0;
    Value err = arg_at(args, argc, 0);
    if !value_is_null(err) && !value_is_undefined(err) {
        vm_promise_settle(vm, p, err, true);
    } else {
        vm_promise_settle(vm, p, arg_at(args, argc, 1), false);
    }
    return value_undefined();
}

private Value nat_promisified(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    Value original = value_as_native(callee).env0;
    Value p = vm_promise_new(vm);
    vm_push(vm, p);
    JsNative* cb = js_new_native(&vm.heap, &nat_promisify_cb, "");
    cb.env0 = p;
    Value cbv = value_cell(&cb.head);
    vm_push(vm, cbv);
    Value* callargs = alloc<Value>(argc + 1);
    for i32 i = 0; i < argc; i++ { *(callargs + i) = *(args + i); }
    *(callargs + argc) = cbv;
    ignore vm_call_value(vm, original, thisv, callargs, argc + 1);
    free(callargs);
    vm_pop(vm);
    vm_pop(vm);
    return p;
}

private Value nat_util_promisify(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    Value orig = arg_at(args, argc, 0);
    if !value_is_callable(orig) {
        vm_throw_error(vm, ERR_TYPE, "The \"original\" argument must be a function");
        return value_undefined();
    }
    vm_push(vm, orig);
    JsNative* w = js_new_native(&vm.heap, &nat_promisified, "");
    w.env0 = orig;
    vm_pop(vm);
    return value_cell(&w.head);
}

// callbackify: on settle, invoke the trailing cb(err, value) as a
// microtask (via a resolved-promise reaction).
private Value nat_callbackify_ok(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    Value cbv = value_as_native(callee).env0;
    Value[2] ca;
    ca[0] = value_null();
    ca[1] = arg_at(args, argc, 0);
    ignore vm_call_value(vm, cbv, value_undefined(), &ca[0], 2);
    return value_undefined();
}
private Value nat_callbackify_err(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    Value cbv = value_as_native(callee).env0;
    Value[1] ca;
    ca[0] = arg_at(args, argc, 0);
    ignore vm_call_value(vm, cbv, value_undefined(), &ca[0], 1);
    return value_undefined();
}
private Value nat_callbackified(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    Value original = value_as_native(callee).env0;
    i32 nargs = argc > 0 ? argc - 1 : 0;
    Value cbv = arg_at(args, argc, nargs);   // last arg is the callback
    i32 rm = gc_root_mark(&vm.heap);
    gc_root(&vm.heap, cbv);
    Value p = vm_call_value(vm, original, thisv, args, nargs);
    gc_root(&vm.heap, p);
    if vm_is_promise(vm, p) {
        JsNative* onok = js_new_native(&vm.heap, &nat_callbackify_ok, "");
        onok.env0 = cbv;
        JsNative* onerr = js_new_native(&vm.heap, &nat_callbackify_err, "");
        onerr.env0 = cbv;
        ignore vm_promise_then(vm, p, value_cell(&onok.head), value_cell(&onerr.head));
    }
    gc_root_reset(&vm.heap, rm);
    return value_undefined();
}
private Value nat_util_callbackify(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    Value orig = arg_at(args, argc, 0);
    if !value_is_callable(orig) {
        vm_throw_error(vm, ERR_TYPE, "The \"original\" argument must be a function");
        return value_undefined();
    }
    vm_push(vm, orig);
    JsNative* w = js_new_native(&vm.heap, &nat_callbackified, "");
    w.env0 = orig;
    vm_pop(vm);
    return value_cell(&w.head);
}

// inspect: the console string form; a top-level string is single-quoted
// (matching Node), unlike console.log.
private Value util_inspect_value(VM* vm, Value v) {
    if value_is_string(v) {
        str s = sview(v);
        str_buf sb;
        str_buf_init(&sb);
        str_buf_add_byte(&sb, cast(u8, 39));   // '
        for i32 i = 0; i < s.len; i++ {
            u8 c = *(s.data + i);
            if c == 39 || c == 92 { str_buf_add_byte(&sb, cast(u8, 92)); }   // escape ' and backslash
            str_buf_add_byte(&sb, c);
        }
        str_buf_add_byte(&sb, cast(u8, 39));
        Value r = new_str(vm, str_buf_to_str(&sb));
        str_buf_free(&sb);
        return r;
    }
    return js_console_string(vm, v);
}

private Value nat_util_inspect(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    return util_inspect_value(as_vm(vmp), arg_at(args, argc, 0));
}

// Appends the number-to-string of `x` (a JS number Value) to sb.
private void util_append_num(VM* vm, str_buf* sb, f64 x) {
    Value s = js_to_string_value(vm, value_number(x));
    str_buf_add(sb, sview(s));
}

private Value nat_util_format(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    str_buf out;
    str_buf_init(&out);
    i32 next = 1;
    Value fmtv = arg_at(args, argc, 0);
    // specifier processing only kicks in with a substitution argument; a
    // lone format string is returned verbatim (Node behavior).
    if argc >= 2 && value_is_string(fmtv) {
        str f = sview(fmtv);
        i32 i = 0;
        while i < f.len {
            u8 c = *(f.data + i);
            if c == '%' && i + 1 < f.len {
                u8 spec = *(f.data + i + 1);
                if spec == '%' { str_buf_add_byte(&out, cast(u8, '%')); i += 2; continue; }
                bool known = spec == 's' || spec == 'd' || spec == 'i' || spec == 'f'
                    || spec == 'j' || spec == 'o' || spec == 'O' || spec == 'c';
                if known {
                    if next >= argc {
                        str_buf_add_byte(&out, cast(u8, '%'));
                        str_buf_add_byte(&out, spec);
                    } else {
                        Value a = *(args + next);
                        next++;
                        i32 rm = gc_root_mark(&vm.heap);
                        gc_root(&vm.heap, a);
                        if spec == 's' {
                            Value s = js_console_string(vm, a);
                            str_buf_add(&out, sview(s));
                        } else if spec == 'd' || spec == 'f' {
                            util_append_num(vm, &out, js_to_number(a));
                        } else if spec == 'i' {
                            f64 n = js_to_number(a);
                            if n != n { str_buf_add(&out, "NaN"); }
                            else { util_append_num(vm, &out, cast(f64, cast(i64, n))); }
                        } else if spec == 'j' {
                            Value jr = nat_json_stringify(vmp, callee, thisv, args + next - 1, 1);
                            if vm.has_pending { vm.has_pending = false; vm.pending = value_undefined(); str_buf_add(&out, "[Circular]"); }
                            else if value_is_string(jr) { str_buf_add(&out, sview(jr)); }
                            else { str_buf_add(&out, "undefined"); }
                        } else if spec == 'c' {
                            // CSS directive: consume the arg, emit nothing
                        } else {
                            Value s = util_inspect_value(vm, a);   // %o / %O
                            str_buf_add(&out, sview(s));
                        }
                        gc_root_reset(&vm.heap, rm);
                    }
                    i += 2;
                    continue;
                }
            }
            str_buf_add_byte(&out, c);
            i++;
        }
    } else {
        next = 0;
    }
    // remaining args (space-joined, console.log-style)
    for i32 k = next; k < argc; k++ {
        if out.len > 0 || k > next { str_buf_add_byte(&out, cast(u8, ' ')); }
        i32 rm = gc_root_mark(&vm.heap);
        Value s = js_console_string(vm, *(args + k));
        gc_root(&vm.heap, s);
        str_buf_add(&out, sview(s));
        gc_root_reset(&vm.heap, rm);
    }
    Value r = new_str(vm, str_buf_to_str(&out));
    str_buf_free(&out);
    return r;
}

private Value nat_util_inherits(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    Value ctor = arg_at(args, argc, 0);
    Value superc = arg_at(args, argc, 1);
    if !value_is_callable(ctor) || !value_is_callable(superc) {
        vm_throw_error(vm, ERR_TYPE, "inherits expects two constructors");
        return value_undefined();
    }
    // super proto
    Value sp;
    JsObject* super_proto = null;
    if vm_get_prop_value(vm, superc, vm.atom_prototype, &sp) && value_is_object(sp) {
        super_proto = value_as_object(sp);
    }
    JsObject* newproto = js_new_object(&vm.heap, super_proto);
    vm_push(vm, value_cell(&newproto.head));
    props_set_desc(&newproto.props, atom_intern(&vm.atoms, "constructor"), ctor, METHOD_ATTRS);
    // set ctor.prototype = newproto, ctor.super_ = superc
    if value_is_native(ctor) {
        props_set_desc(&value_as_native(ctor).props, vm.atom_prototype, value_cell(&newproto.head), PROP_WRITABLE);
        props_set_desc(&value_as_native(ctor).props, atom_intern(&vm.atoms, "super_"), superc, PROP_DEFAULT);
    } else if value_is_function(ctor) {
        props_set_desc(&value_as_function(ctor).props, vm.atom_prototype, value_cell(&newproto.head), PROP_WRITABLE);
        props_set_desc(&value_as_function(ctor).props, atom_intern(&vm.atoms, "super_"), superc, PROP_DEFAULT);
    }
    vm_pop(vm);
    return value_undefined();
}

// deprecate: passthrough wrapper (env0 = original fn). No warning emitted.
private Value nat_deprecated_call(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    return vm_call_value(vm, value_as_native(callee).env0, thisv, args, argc);
}
private Value nat_util_deprecate(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    Value orig = arg_at(args, argc, 0);
    if !value_is_callable(orig) { return orig; }
    vm_push(vm, orig);
    JsNative* w = js_new_native(&vm.heap, &nat_deprecated_call, "deprecated");
    w.env0 = orig;
    vm_pop(vm);
    return value_cell(&w.head);
}

// --- util.isDeepStrictEqual ---

private bool proto_chain_has(Value v, JsObject* target) {
    if !value_is_object(v) && !value_is_array(v) { return false; }
    JsObject* cur = value_as_object(v).proto;
    while cur != null {
        if cur == target { return true; }
        cur = cur.proto;
    }
    return false;
}

private bool deep_equal(VM* vm, Value a, Value b, i32 depth) {
    if depth > 200 { return false; }
    if js_same_value(a, b) { return true; }
    // both dates: compare time value
    if proto_chain_has(a, vm.date_proto) && proto_chain_has(b, vm.date_proto) {
        Value ta;
        Value tb;
        u32 tatom = atom_intern(&vm.atoms, "%t");
        bool ha = js_get_prop(value_as_object(a), tatom, &ta);
        bool hb = js_get_prop(value_as_object(b), tatom, &tb);
        if ha && hb { return js_to_number(ta) == js_to_number(tb); }
    }
    bool aarr = value_is_array(a);
    bool barr = value_is_array(b);
    if aarr != barr { return false; }
    if aarr {
        JsObject* ao = value_as_object(a);
        JsObject* bo = value_as_object(b);
        if ao.elen != bo.elen { return false; }
        for i32 i = 0; i < ao.elen; i++ {
            if !deep_equal(vm, js_array_get(ao, i), js_array_get(bo, i), depth + 1) { return false; }
        }
        return true;
    }
    if value_is_object(a) && value_is_object(b) {
        i32 rm = gc_root_mark(&vm.heap);
        JsObject* ak = vm_own_keys(vm, a);
        gc_root(&vm.heap, value_cell(&ak.head));
        JsObject* bk = vm_own_keys(vm, b);
        gc_root(&vm.heap, value_cell(&bk.head));
        bool eq = ak.elen == bk.elen;
        for i32 i = 0; eq && i < ak.elen; i++ {
            Value kv = js_array_get(ak, i);
            u32 katom = atom_intern(&vm.atoms, sview(kv));
            Value av;
            Value bv;
            bool hb = js_get_prop(value_as_object(b), katom, &bv);
            bool ha = js_get_prop(value_as_object(a), katom, &av);
            if !ha || !hb || !deep_equal(vm, av, bv, depth + 1) { eq = false; }
        }
        gc_root_reset(&vm.heap, rm);
        return eq;
    }
    return false;
}

private Value nat_util_deep_equal(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    return value_bool(deep_equal(vm, arg_at(args, argc, 0), arg_at(args, argc, 1), 0));
}

// --- util.types ---

private Value nat_types_is_date(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    return value_bool(proto_chain_has(arg_at(args, argc, 0), as_vm(vmp).date_proto));
}
private Value nat_types_is_regexp(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    return value_bool(proto_chain_has(arg_at(args, argc, 0), as_vm(vmp).regexp_proto));
}
private Value nat_types_is_map(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    Value v = arg_at(args, argc, 0);
    return value_bool(value_is_map(v) && !value_as_map(v).is_set);
}
private Value nat_types_is_set(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    Value v = arg_at(args, argc, 0);
    return value_bool(value_is_map(v) && value_as_map(v).is_set);
}
private Value nat_types_is_promise(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    return value_bool(vm_is_promise(as_vm(vmp), arg_at(args, argc, 0)));
}
private Value nat_types_is_native_error(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    return value_bool(proto_chain_has(arg_at(args, argc, 0), as_vm(vmp).error_protos[ERR_ERROR]));
}
private Value nat_types_is_async_fn(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    Value v = arg_at(args, argc, 0);
    return value_bool(value_is_function(v) && value_as_function(v).tmpl != null && value_as_function(v).tmpl.is_async);
}
private Value nat_types_is_gen_fn(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    Value v = arg_at(args, argc, 0);
    return value_bool(value_is_function(v) && value_as_function(v).tmpl != null && value_as_function(v).tmpl.is_gen);
}
private Value nat_types_false(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    return value_bool(false);
}

private Value util_global(VM* vm, str name) {
    Value* g = intmap_get<Value>(&vm.globals, bi_atom(vm, name));
    if g != null { return *g; }
    return value_undefined();
}

private JsObject* build_util_module(VM* vm) {
    JsObject* mod;
    JsObject* ns = new_node_module(vm, &mod);
    def_node_export(vm, mod, ns, "promisify", &nat_util_promisify);
    def_node_export(vm, mod, ns, "callbackify", &nat_util_callbackify);
    def_node_export(vm, mod, ns, "format", &nat_util_format);
    def_node_export(vm, mod, ns, "inspect", &nat_util_inspect);
    def_node_export(vm, mod, ns, "inherits", &nat_util_inherits);
    def_node_export(vm, mod, ns, "deprecate", &nat_util_deprecate);
    def_node_export(vm, mod, ns, "isDeepStrictEqual", &nat_util_deep_equal);
    def_node_value(vm, mod, ns, "TextEncoder", util_global(vm, "TextEncoder"));
    def_node_value(vm, mod, ns, "TextDecoder", util_global(vm, "TextDecoder"));

    // util.types
    JsObject* types = js_new_object(&vm.heap, vm.object_proto);
    def_node_value(vm, mod, ns, "types", value_cell(&types.head));
    def_method(vm, types, "isDate", &nat_types_is_date);
    def_method(vm, types, "isRegExp", &nat_types_is_regexp);
    def_method(vm, types, "isMap", &nat_types_is_map);
    def_method(vm, types, "isSet", &nat_types_is_set);
    def_method(vm, types, "isPromise", &nat_types_is_promise);
    def_method(vm, types, "isNativeError", &nat_types_is_native_error);
    def_method(vm, types, "isAsyncFunction", &nat_types_is_async_fn);
    def_method(vm, types, "isGeneratorFunction", &nat_types_is_gen_fn);
    def_method(vm, types, "isTypedArray", &nat_types_false);
    def_method(vm, types, "isArrayBuffer", &nat_types_false);
    def_method(vm, types, "isProxy", &nat_types_false);
    return ns;
}

// --- crypto -----------------------------------------------------------------
//
// SHA-256 (FIPS 180-4) plus a platform CSPRNG for randomBytes / randomUUID.

private u32 sha_rotr(u32 x, u32 n) { return (x >> n) | (x << (32 - n)); }

private void sha256_block(u8* block, u32* state, u32* k) {
    u32[64] w;
    for i32 i = 0; i < 16; i++ {
        i32 off = i * 4;
        u32 b0 = cast(u32, *(block + off));
        u32 b1 = cast(u32, *(block + off + 1));
        u32 b2 = cast(u32, *(block + off + 2));
        u32 b3 = cast(u32, *(block + off + 3));
        w[i] = (b0 << 24) | (b1 << 16) | (b2 << 8) | b3;
    }
    for i32 i = 16; i < 64; i++ {
        u32 w15 = w[i - 15];
        u32 w2 = w[i - 2];
        u32 s0 = sha_rotr(w15, 7) ^ sha_rotr(w15, 18) ^ (w15 >> 3);
        u32 s1 = sha_rotr(w2, 17) ^ sha_rotr(w2, 19) ^ (w2 >> 10);
        w[i] = w[i - 16] + s0 + w[i - 7] + s1;
    }
    // working variables in a small memory-backed array
    u32[8] v;
    for i32 i = 0; i < 8; i++ { v[i] = *(state + i); }
    for i32 i = 0; i < 64; i++ {
        u32 e = v[4];
        u32 S1 = sha_rotr(e, 6) ^ sha_rotr(e, 11) ^ sha_rotr(e, 25);
        u32 ch = v[6] ^ (e & (v[5] ^ v[6]));
        u32 t1 = v[7] + S1 + ch + *(k + i) + w[i];
        u32 a = v[0];
        u32 S0 = sha_rotr(a, 2) ^ sha_rotr(a, 13) ^ sha_rotr(a, 22);
        u32 maj = (a & v[1]) ^ (a & v[2]) ^ (v[1] & v[2]);
        u32 t2 = S0 + maj;
        v[7] = v[6]; v[6] = v[5]; v[5] = v[4]; v[4] = v[3] + t1;
        v[3] = v[2]; v[2] = v[1]; v[1] = v[0]; v[0] = t1 + t2;
    }
    for i32 i = 0; i < 8; i++ { *(state + i) = *(state + i) + v[i]; }
}

// Hashes `len` bytes at `data` into 32 output bytes.
private void sha256_hash(u8* data, i32 len, u8* out) {
    u32[64] k = {
        0x428A2F98, 0x71374491, 0xB5C0FBCF, 0xE9B5DBA5, 0x3956C25B, 0x59F111F1, 0x923F82A4, 0xAB1C5ED5,
        0xD807AA98, 0x12835B01, 0x243185BE, 0x550C7DC3, 0x72BE5D74, 0x80DEB1FE, 0x9BDC06A7, 0xC19BF174,
        0xE49B69C1, 0xEFBE4786, 0x0FC19DC6, 0x240CA1CC, 0x2DE92C6F, 0x4A7484AA, 0x5CB0A9DC, 0x76F988DA,
        0x983E5152, 0xA831C66D, 0xB00327C8, 0xBF597FC7, 0xC6E00BF3, 0xD5A79147, 0x06CA6351, 0x14292967,
        0x27B70A85, 0x2E1B2138, 0x4D2C6DFC, 0x53380D13, 0x650A7354, 0x766A0ABB, 0x81C2C92E, 0x92722C85,
        0xA2BFE8A1, 0xA81A664B, 0xC24B8B70, 0xC76C51A3, 0xD192E819, 0xD6990624, 0xF40E3585, 0x106AA070,
        0x19A4C116, 0x1E376C08, 0x2748774C, 0x34B0BCB5, 0x391C0CB3, 0x4ED8AA4A, 0x5B9CCA4F, 0x682E6FF3,
        0x748F82EE, 0x78A5636F, 0x84C87814, 0x8CC70208, 0x90BEFFFA, 0xA4506CEB, 0xBEF9A3F7, 0xC67178F2
    };
    u32[8] state = {
        0x6A09E667, 0xBB67AE85, 0x3C6EF372, 0xA54FF53A, 0x510E527F, 0x9B05688C, 0x1F83D9AB, 0x5BE0CD19
    };
    i32 pos = 0;
    while pos + 64 <= len {
        sha256_block(data + pos, &state[0], &k[0]);
        pos = pos + 64;
    }
    u8[128] final_buf;
    memset(cast(void*, &final_buf[0]), 0, 128);
    i32 remaining = len - pos;
    if remaining > 0 { memcpy(cast(void*, &final_buf[0]), cast(void*, data + pos), cast(i64, remaining)); }
    final_buf[remaining] = 0x80;
    if remaining >= 56 {
        sha256_block(&final_buf[0], &state[0], &k[0]);
        memset(cast(void*, &final_buf[0]), 0, 64);
    }
    i64 bitlen = cast(i64, len) * 8;
    final_buf[56] = cast(u8, bitlen >> 56);
    final_buf[57] = cast(u8, (bitlen >> 48) & 0xFF);
    final_buf[58] = cast(u8, (bitlen >> 40) & 0xFF);
    final_buf[59] = cast(u8, (bitlen >> 32) & 0xFF);
    final_buf[60] = cast(u8, (bitlen >> 24) & 0xFF);
    final_buf[61] = cast(u8, (bitlen >> 16) & 0xFF);
    final_buf[62] = cast(u8, (bitlen >> 8) & 0xFF);
    final_buf[63] = cast(u8, bitlen & 0xFF);
    sha256_block(&final_buf[0], &state[0], &k[0]);
    for i32 i = 0; i < 8; i++ {
        u32 v = state[i];
        *(out + i * 4) = cast(u8, v >> 24);
        *(out + i * 4 + 1) = cast(u8, (v >> 16) & 0xFF);
        *(out + i * 4 + 2) = cast(u8, (v >> 8) & 0xFF);
        *(out + i * 4 + 3) = cast(u8, v & 0xFF);
    }
}

// MD5 (RFC 1321). Legacy, but createHash('md5') is common; cifra ships no MD5.

private u32 md5_lrot(u32 x, u32 c) { return (x << c) | (x >> (32 - c)); }

private void md5_block(u8* block, u32* st, u32* kt, u8* sh) {
    u32[16] m;
    for i32 i = 0; i < 16; i++ {
        i32 off = i * 4;
        u32 b0 = cast(u32, *(block + off));
        u32 b1 = cast(u32, *(block + off + 1));
        u32 b2 = cast(u32, *(block + off + 2));
        u32 b3 = cast(u32, *(block + off + 3));
        m[i] = b0 | (b1 << 8) | (b2 << 16) | (b3 << 24);   // little-endian
    }
    u32 a = *(st + 0);
    u32 b = *(st + 1);
    u32 c = *(st + 2);
    u32 d = *(st + 3);
    for i32 i = 0; i < 64; i++ {
        u32 f;
        i32 g;
        if i < 16 { f = (b & c) | ((~b) & d); g = i; }
        else if i < 32 { f = (d & b) | ((~d) & c); g = (5 * i + 1) & 15; }
        else if i < 48 { f = b ^ c ^ d; g = (3 * i + 5) & 15; }
        else { f = c ^ (b | (~d)); g = (7 * i) & 15; }
        f = f + a + *(kt + i) + m[g];
        a = d; d = c; c = b;
        b = b + md5_lrot(f, cast(u32, *(sh + i)));
    }
    *(st + 0) = *(st + 0) + a;
    *(st + 1) = *(st + 1) + b;
    *(st + 2) = *(st + 2) + c;
    *(st + 3) = *(st + 3) + d;
}

private void md5_hash(u8* data, i32 len, u8* out) {
    u32[64] kt = {
        0xD76AA478, 0xE8C7B756, 0x242070DB, 0xC1BDCEEE, 0xF57C0FAF, 0x4787C62A, 0xA8304613, 0xFD469501,
        0x698098D8, 0x8B44F7AF, 0xFFFF5BB1, 0x895CD7BE, 0x6B901122, 0xFD987193, 0xA679438E, 0x49B40821,
        0xF61E2562, 0xC040B340, 0x265E5A51, 0xE9B6C7AA, 0xD62F105D, 0x02441453, 0xD8A1E681, 0xE7D3FBC8,
        0x21E1CDE6, 0xC33707D6, 0xF4D50D87, 0x455A14ED, 0xA9E3E905, 0xFCEFA3F8, 0x676F02D9, 0x8D2A4C8A,
        0xFFFA3942, 0x8771F681, 0x6D9D6122, 0xFDE5380C, 0xA4BEEA44, 0x4BDECFA9, 0xF6BB4B60, 0xBEBFBC70,
        0x289B7EC6, 0xEAA127FA, 0xD4EF3085, 0x04881D05, 0xD9D4D039, 0xE6DB99E5, 0x1FA27CF8, 0xC4AC5665,
        0xF4292244, 0x432AFF97, 0xAB9423A7, 0xFC93A039, 0x655B59C3, 0x8F0CCC92, 0xFFEFF47D, 0x85845DD1,
        0x6FA87E4F, 0xFE2CE6E0, 0xA3014314, 0x4E0811A1, 0xF7537E82, 0xBD3AF235, 0x2AD7D2BB, 0xEB86D391
    };
    u8[64] sh = {
        7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
        5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
        4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
        6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21
    };
    u32[4] st = { 0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476 };
    i32 pos = 0;
    while pos + 64 <= len {
        md5_block(data + pos, &st[0], &kt[0], &sh[0]);
        pos = pos + 64;
    }
    u8[128] fb;
    memset(cast(void*, &fb[0]), 0, 128);
    i32 rem = len - pos;
    if rem > 0 { memcpy(cast(void*, &fb[0]), cast(void*, data + pos), cast(i64, rem)); }
    fb[rem] = 0x80;
    i32 nb = rem >= 56 ? 128 : 64;
    i64 bitlen = cast(i64, len) * 8;
    for i32 i = 0; i < 8; i++ { fb[nb - 8 + i] = cast(u8, (bitlen >> (i * 8)) & 0xFF); }   // little-endian length
    md5_block(&fb[0], &st[0], &kt[0], &sh[0]);
    if nb == 128 { md5_block(&fb[64], &st[0], &kt[0], &sh[0]); }
    for i32 i = 0; i < 4; i++ {
        u32 v = st[i];
        *(out + i * 4) = cast(u8, v & 0xFF);
        *(out + i * 4 + 1) = cast(u8, (v >> 8) & 0xFF);
        *(out + i * 4 + 2) = cast(u8, (v >> 16) & 0xFF);
        *(out + i * 4 + 3) = cast(u8, (v >> 24) & 0xFF);
    }
}

// SHA-1 (FIPS 180-4). Legacy, but createHash('sha1') is common; cifra ships no SHA-1.

private u32 sha1_lrot(u32 x, u32 n) { return (x << n) | (x >> (32 - n)); }

private void sha1_block(u8* block, u32* h) {
    u32[80] w;
    for i32 i = 0; i < 16; i++ {
        i32 off = i * 4;
        u32 b0 = cast(u32, *(block + off));
        u32 b1 = cast(u32, *(block + off + 1));
        u32 b2 = cast(u32, *(block + off + 2));
        u32 b3 = cast(u32, *(block + off + 3));
        w[i] = (b0 << 24) | (b1 << 16) | (b2 << 8) | b3;
    }
    for i32 i = 16; i < 80; i++ {
        u32 v = w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16];
        w[i] = sha1_lrot(v, 1);
    }
    u32 a = *(h + 0);
    u32 b = *(h + 1);
    u32 c = *(h + 2);
    u32 d = *(h + 3);
    u32 e = *(h + 4);
    for i32 i = 0; i < 80; i++ {
        u32 f;
        u32 k;
        if i < 20 { f = (b & c) | ((~b) & d); k = 0x5A827999; }
        else if i < 40 { f = b ^ c ^ d; k = 0x6ED9EBA1; }
        else if i < 60 { f = (b & c) | (b & d) | (c & d); k = 0x8F1BBCDC; }
        else { f = b ^ c ^ d; k = 0xCA62C1D6; }
        u32 t = sha1_lrot(a, 5) + f + e + k + w[i];
        e = d; d = c; c = sha1_lrot(b, 30); b = a; a = t;
    }
    *(h + 0) = *(h + 0) + a;
    *(h + 1) = *(h + 1) + b;
    *(h + 2) = *(h + 2) + c;
    *(h + 3) = *(h + 3) + d;
    *(h + 4) = *(h + 4) + e;
}

private void sha1_hash(u8* data, i32 len, u8* out) {
    u32[5] h = { 0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0 };
    i32 pos = 0;
    while pos + 64 <= len {
        sha1_block(data + pos, &h[0]);
        pos = pos + 64;
    }
    u8[128] fb;
    memset(cast(void*, &fb[0]), 0, 128);
    i32 rem = len - pos;
    if rem > 0 { memcpy(cast(void*, &fb[0]), cast(void*, data + pos), cast(i64, rem)); }
    fb[rem] = 0x80;
    i32 nb = rem >= 56 ? 128 : 64;
    i64 bitlen = cast(i64, len) * 8;
    for i32 i = 0; i < 8; i++ { fb[nb - 1 - i] = cast(u8, (bitlen >> (i * 8)) & 0xFF); }   // big-endian length
    sha1_block(&fb[0], &h[0]);
    if nb == 128 { sha1_block(&fb[64], &h[0]); }
    for i32 i = 0; i < 5; i++ {
        u32 v = h[i];
        *(out + i * 4) = cast(u8, v >> 24);
        *(out + i * 4 + 1) = cast(u8, (v >> 16) & 0xFF);
        *(out + i * 4 + 2) = cast(u8, (v >> 8) & 0xFF);
        *(out + i * 4 + 3) = cast(u8, v & 0xFF);
    }
}

// Digest algorithms are keyed by their output length, which is unique across
// the supported set: md5=16, sha1=20, sha256=32, sha384=48, sha512=64.
// Returns the length, or -1 for an unsupported name.
private i32 crypto_algo_id(str a) {
    if ci_eq(a, "md5") { return 16; }
    if ci_eq(a, "sha1") || ci_eq(a, "sha-1") { return 20; }
    if ci_eq(a, "sha256") || ci_eq(a, "sha-256") { return 32; }
    if ci_eq(a, "sha384") || ci_eq(a, "sha-384") { return 48; }
    if ci_eq(a, "sha512") || ci_eq(a, "sha-512") { return 64; }
    return 0 - 1;
}

// HMAC block size: 64 for md5/sha1/sha256, 128 for sha384/sha512.
private i32 crypto_algo_block_len(i32 dlen) { return dlen <= 32 ? 64 : 128; }

// One-shot hash of `len` bytes at `data` into `dlen` output bytes.
private void crypto_algo_hash(i32 dlen, u8* data, i32 len, u8* out) {
    if dlen == 16 { md5_hash(data, len, out); }
    else if dlen == 20 { sha1_hash(data, len, out); }
    else if dlen == 32 { sha256_hash(data, len, out); }
    else if dlen == 48 {
        cf_sha512_context st;
        cf_sha384_init(&st);
        cf_sha384_update(&st, cast(void*, data), cast(u64, len));
        cf_sha384_digest_final(&st, out);
    } else {
        cf_sha512_context st;
        cf_sha512_init(&st);
        cf_sha512_update(&st, cast(void*, data), cast(u64, len));
        cf_sha512_digest_final(&st, out);
    }
}

// HMAC (RFC 2104): H((K0^opad) || H((K0^ipad) || msg)), where K0 is the key
// hashed down if it exceeds the block, else zero-padded to the block.
private void hmac_compute(i32 dlen, u8* key, i32 klen, u8* msg, i32 mlen, u8* out) {
    i32 bs = crypto_algo_block_len(dlen);
    u8* k0 = alloc<u8>(bs);
    memset(cast(void*, k0), 0, cast(i64, bs));
    if klen > bs {
        crypto_algo_hash(dlen, key, klen, k0);   // rest of k0 stays zero
    } else if klen > 0 {
        memcpy(cast(void*, k0), cast(void*, key), cast(i64, klen));
    }
    i32 inner_len = bs + mlen;
    u8* inner = alloc<u8>(inner_len > 0 ? inner_len : 1);
    for i32 i = 0; i < bs; i++ { *(inner + i) = *(k0 + i) ^ 0x36; }
    if mlen > 0 { memcpy(cast(void*, inner + bs), cast(void*, msg), cast(i64, mlen)); }
    u8[64] ihash;
    crypto_algo_hash(dlen, inner, inner_len, &ihash[0]);
    i32 outer_len = bs + dlen;
    u8* outer = alloc<u8>(outer_len);
    for i32 i = 0; i < bs; i++ { *(outer + i) = *(k0 + i) ^ 0x5C; }
    memcpy(cast(void*, outer + bs), cast(void*, &ihash[0]), cast(i64, dlen));
    crypto_algo_hash(dlen, outer, outer_len, out);
    free(k0);
    free(inner);
    free(outer);
}

// Platform CSPRNG: fills `n` bytes at `buf`. Returns false if unavailable.
when os(windows) {
    private extern "advapi32.dll" u8 SystemFunction036(void* buf, u32 len);
    private bool os_random(u8* buf, i32 n) { return SystemFunction036(cast(void*, buf), cast(u32, n)) != 0; }
}
else when os(macos) || os(ios) {
    private extern "libSystem.B.dylib" void arc4random_buf(void* buf, u64 n);
    private bool os_random(u8* buf, i32 n) { arc4random_buf(cast(void*, buf), cast(u64, n)); return true; }
}
else when os(linux) {
    private extern "libc.so.6" i64 getrandom(void* buf, u64 len, u32 flags);
    private bool os_random(u8* buf, i32 n) {
        i32 got = 0;
        while got < n {
            i64 r = getrandom(cast(void*, buf + got), cast(u64, n - got), 0);
            if r <= 0 { return got > 0; }
            got += cast(i32, r);
        }
        return true;
    }
}
else when os(android) {
    private extern "libc.so" i64 getrandom(void* buf, u64 len, u32 flags);
    private bool os_random(u8* buf, i32 n) {
        i32 got = 0;
        while got < n {
            i64 r = getrandom(cast(void*, buf + got), cast(u64, n - got), 0);
            if r <= 0 { return got > 0; }
            got += cast(i32, r);
        }
        return true;
    }
}
else when os(wasm) {
    // No entropy import in the host surface. Reporting unavailable makes
    // crypto.randomBytes/randomUUID throw, which is the right outcome —
    // a non-CSPRNG substitute here would be worse than an error.
    private bool os_random(u8* buf, i32 n) { return false; }
}
else {
    // No arm for this target. Add a `when os(...)` arm above rather
    // than letting it fall back to another platform's syscalls.
    tsmc_unsupported_target__add_a_when_os_arm _unsupported_random;
}

// Coerce a key/data argument to a byte Buffer: a Buffer passes through, a
// string is encoded as UTF-8.
private Value crypto_to_byte_buffer(VM* vm, Value v) {
    if value_is_array(v) { return v; }
    Value s = js_to_string_value(vm, v);
    vm_push(vm, s);
    str_buf sb;
    str_buf_init(&sb);
    str_to_bytes(&sb, sview(s), ENC_UTF8);
    Value b = buf_from_bytes(vm, sb.data, sb.len);
    str_buf_free(&sb);
    vm_pop(vm);
    return b;
}

// digest([encoding]): a Buffer of the raw bytes, or an encoded string when an
// encoding is given. Shared by Hash and Hmac.
private Value crypto_finalize_digest(VM* vm, u8* bytes, i32 dlen, Value encv) {
    Value b = buf_from_bytes(vm, bytes, dlen);
    if value_is_string(encv) {
        vm_push(vm, b);
        i32 enc = buf_parse_enc(encv, ENC_HEX);
        Value r = bytes_to_str(vm, value_as_object(b), enc, 0, dlen);
        vm_pop(vm);
        return r;
    }
    return b;
}

private Value nat_crypto_create_hash(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    Value algv = js_to_string_value(vm, arg_at(args, argc, 0));
    vm_push(vm, algv);
    i32 id = crypto_algo_id(sview(algv));
    if id < 0 {
        vm_pop(vm);
        vm_throw_error(vm, ERR_ERROR, "Digest method not supported");
        return value_undefined();
    }
    JsObject* h = js_new_object(&vm.heap, vm.crypto_hash_proto);
    vm_push(vm, value_cell(&h.head));
    Value accbuf = buf_from_bytes(vm, null, 0);
    vm_push(vm, accbuf);
    props_set_desc(&h.props, bi_atom(vm, "%buf"), accbuf, 0);
    props_set_desc(&h.props, bi_atom(vm, "%algo"), value_number(cast(f64, id)), 0);
    vm_pop(vm);   // accbuf
    vm_pop(vm);   // h
    vm_pop(vm);   // algv
    return value_cell(&h.head);
}

// Appends the bytes of `data` (string in `enc`, or a Buffer) to the hash's
// accumulator.
private Value nat_hash_update(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    if !value_is_object(thisv) { return thisv; }
    Value bufv;
    if !js_get_prop(value_as_object(thisv), bi_atom(vm, "%buf"), &bufv) || !value_is_array(bufv) {
        return thisv;
    }
    JsObject* acc = value_as_object(bufv);
    Value data = arg_at(args, argc, 0);
    if value_is_array(data) {
        JsObject* b = value_as_object(data);
        for i32 i = 0; i < b.elen; i++ { js_array_set(acc, acc.elen, value_number(cast(f64, buf_byte(b, i)))); }
    } else {
        i32 enc = buf_parse_enc(arg_at(args, argc, 1), ENC_UTF8);
        Value s = js_to_string_value(vm, data);
        vm_push(vm, s);
        str_buf sb;
        str_buf_init(&sb);
        str_to_bytes(&sb, sview(s), enc);
        for i32 i = 0; i < sb.len; i++ { js_array_set(acc, acc.elen, value_number(cast(f64, *(sb.data + i)))); }
        str_buf_free(&sb);
        vm_pop(vm);
    }
    return thisv;
}

private Value nat_hash_digest(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    Value bufv;
    if !value_is_object(thisv)
        || !js_get_prop(value_as_object(thisv), bi_atom(vm, "%buf"), &bufv)
        || !value_is_array(bufv) {
        return value_undefined();
    }
    JsObject* self = value_as_object(thisv);
    i32 id = 32;
    Value algov;
    if js_get_prop(self, bi_atom(vm, "%algo"), &algov) && value_is_number(algov) {
        id = cast(i32, value_as_f64(algov));
    }
    JsObject* acc = value_as_object(bufv);
    i32 n = acc.elen;
    u8* data = alloc<u8>(n > 0 ? n : 1);
    for i32 i = 0; i < n; i++ { *(data + i) = cast(u8, buf_byte(acc, i)); }
    u8[64] digest;
    crypto_algo_hash(id, data, n, &digest[0]);
    free(data);
    return crypto_finalize_digest(vm, &digest[0], id, arg_at(args, argc, 0));
}

private Value nat_crypto_create_hmac(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    Value algv = js_to_string_value(vm, arg_at(args, argc, 0));
    vm_push(vm, algv);
    i32 id = crypto_algo_id(sview(algv));
    if id < 0 {
        vm_pop(vm);
        vm_throw_error(vm, ERR_ERROR, "Digest method not supported");
        return value_undefined();
    }
    Value keybuf = crypto_to_byte_buffer(vm, arg_at(args, argc, 1));
    vm_push(vm, keybuf);
    JsObject* h = js_new_object(&vm.heap, vm.crypto_hmac_proto);
    vm_push(vm, value_cell(&h.head));
    Value accbuf = buf_from_bytes(vm, null, 0);
    vm_push(vm, accbuf);
    props_set_desc(&h.props, bi_atom(vm, "%buf"), accbuf, 0);
    props_set_desc(&h.props, bi_atom(vm, "%algo"), value_number(cast(f64, id)), 0);
    props_set_desc(&h.props, bi_atom(vm, "%key"), keybuf, 0);
    vm_pop(vm);   // accbuf
    vm_pop(vm);   // h
    vm_pop(vm);   // keybuf
    vm_pop(vm);   // algv
    return value_cell(&h.head);
}

private Value nat_hmac_digest(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    if !value_is_object(thisv) { return value_undefined(); }
    JsObject* self = value_as_object(thisv);
    Value bufv;
    Value keyv;
    if !js_get_prop(self, bi_atom(vm, "%buf"), &bufv) || !value_is_array(bufv) { return value_undefined(); }
    if !js_get_prop(self, bi_atom(vm, "%key"), &keyv) || !value_is_array(keyv) { return value_undefined(); }
    i32 id = 32;
    Value algov;
    if js_get_prop(self, bi_atom(vm, "%algo"), &algov) && value_is_number(algov) {
        id = cast(i32, value_as_f64(algov));
    }
    JsObject* msg = value_as_object(bufv);
    JsObject* key = value_as_object(keyv);
    i32 mlen = msg.elen;
    i32 klen = key.elen;
    u8* mbytes = alloc<u8>(mlen > 0 ? mlen : 1);
    for i32 i = 0; i < mlen; i++ { *(mbytes + i) = cast(u8, buf_byte(msg, i)); }
    u8* kbytes = alloc<u8>(klen > 0 ? klen : 1);
    for i32 i = 0; i < klen; i++ { *(kbytes + i) = cast(u8, buf_byte(key, i)); }
    u8[64] out;
    hmac_compute(id, kbytes, klen, mbytes, mlen, &out[0]);
    free(mbytes);
    free(kbytes);
    return crypto_finalize_digest(vm, &out[0], id, arg_at(args, argc, 0));
}

private Value nat_crypto_random_bytes(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    i32 n = to_int_arg(arg_at(args, argc, 0));
    if n < 0 { n = 0; }
    u8* buf = alloc<u8>(n > 0 ? n : 1);
    if !os_random(buf, n) {
        free(buf);
        vm_throw_error(vm, ERR_ERROR, "randomBytes: no secure random source");
        return value_undefined();
    }
    Value r = buf_from_bytes(vm, buf, n);
    free(buf);
    return r;
}

// crypto.randomFillSync(buf[, offset[, size]]): fill buf in place with random
// bytes and return it. Accepts a Buffer (array-backed) or a typed array.
private Value nat_crypto_random_fill_sync(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    Value bufv = arg_at(args, argc, 0);
    if !value_is_object(bufv) {
        vm_throw_error(vm, ERR_TYPE, "randomFillSync: argument must be a Buffer or TypedArray");
        return value_undefined();
    }
    JsObject* o = value_as_object(bufv);
    bool is_ta = (o.obj_flags & OBJF_TYPEDARRAY) != 0;
    i32 len = is_ta ? ta_len(vm, o) : o.elen;
    i32 off = value_is_undefined(arg_at(args, argc, 1)) ? 0 : to_int_arg(arg_at(args, argc, 1));
    if off < 0 { off = 0; }
    if off > len { off = len; }
    i32 size = value_is_undefined(arg_at(args, argc, 2)) ? len - off : to_int_arg(arg_at(args, argc, 2));
    if size < 0 { size = 0; }
    if off + size > len { size = len - off; }
    if size > 0 {
        u8* rnd = alloc<u8>(size);
        if !os_random(rnd, size) {
            free(rnd);
            vm_throw_error(vm, ERR_ERROR, "randomFillSync: no secure random source");
            return value_undefined();
        }
        for i32 i = 0; i < size; i++ {
            i32 bv = cast(i32, rnd[i]);
            if is_ta { vm_ta_set(vm, o, off + i, value_int(bv)); }
            else { js_array_set(o, off + i, value_number(cast(f64, bv))); }
        }
        free(rnd);
    }
    return bufv;
}

private Value nat_crypto_random_uuid(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    u8[16] b;
    if !os_random(&b[0], 16) {
        vm_throw_error(vm, ERR_ERROR, "randomUUID: no secure random source");
        return value_undefined();
    }
    b[6] = cast(u8, (b[6] & 0x0F) | 0x40);   // version 4
    b[8] = cast(u8, (b[8] & 0x3F) | 0x80);   // variant 1
    str hexd = "0123456789abcdef";
    u8[36] out;
    i32 p = 0;
    for i32 i = 0; i < 16; i++ {
        if i == 4 || i == 6 || i == 8 || i == 10 { out[p] = cast(u8, '-'); p++; }
        out[p] = *(hexd.data + (b[i] >> 4)); p++;
        out[p] = *(hexd.data + (b[i] & 0xF)); p++;
    }
    str s;
    s.data = &out[0];
    s.len = 36;
    return new_str(vm, s);
}

private JsObject* build_crypto_module(VM* vm) {
    vm.crypto_hash_proto = js_new_object(&vm.heap, vm.object_proto);
    def_method(vm, vm.crypto_hash_proto, "update", &nat_hash_update);
    def_method(vm, vm.crypto_hash_proto, "digest", &nat_hash_digest);

    // Hmac shares update() (both accumulate into %buf); only digest differs.
    vm.crypto_hmac_proto = js_new_object(&vm.heap, vm.object_proto);
    def_method(vm, vm.crypto_hmac_proto, "update", &nat_hash_update);
    def_method(vm, vm.crypto_hmac_proto, "digest", &nat_hmac_digest);

    JsObject* mod;
    JsObject* ns = new_node_module(vm, &mod);
    def_node_export(vm, mod, ns, "createHash", &nat_crypto_create_hash);
    def_node_export(vm, mod, ns, "createHmac", &nat_crypto_create_hmac);
    def_node_export(vm, mod, ns, "randomBytes", &nat_crypto_random_bytes);
    def_node_export(vm, mod, ns, "randomFillSync", &nat_crypto_random_fill_sync);
    def_node_export(vm, mod, ns, "randomUUID", &nat_crypto_random_uuid);
    return ns;
}

// --- zlib -------------------------------------------------------------------
//
// zlib / gzip framing over the stdlib's raw DEFLATE (`deflate`/`inflate`).

private u32 zlib_adler32(u8* data, i32 n) {
    u32 a = 1;
    u32 b = 0;
    for i32 i = 0; i < n; i++ {
        a = (a + cast(u32, *(data + i))) % 65521;
        b = (b + a) % 65521;
    }
    return (b << 16) | a;
}

private u32 zlib_crc32(u8* data, i32 n) {
    u32 crc = 0xFFFFFFFF;
    for i32 i = 0; i < n; i++ {
        crc = crc ^ cast(u32, *(data + i));
        for i32 j = 0; j < 8; j++ {
            u32 mask = 0 - (crc & 1);
            crc = (crc >> 1) ^ (0xEDB88320 & mask);
        }
    }
    return crc ^ 0xFFFFFFFF;
}

// Raw DEFLATE compression; returns a heap buffer (caller frees) or null.
private u8* zlib_deflate_raw(u8* src, i32 n, i32* outlen) {
    i32 cap = n * 2 + 1024;
    while cap <= 268435456 {
        u8* dst = alloc<u8>(cap);
        i32 used = 0;
        i32 r = deflate(src, n, dst, cap, &used);
        if r == 0 { *outlen = used; return dst; }
        free(dst);
        if r != 0 - 1 { return null; }   // not an overflow: real error
        cap = cap * 2;
    }
    return null;
}

// Raw DEFLATE decompression; `hint` sizes the initial buffer (0 = default).
private u8* zlib_inflate_raw(u8* src, i32 n, i32 hint, i32* outlen) {
    i32 cap = hint > 0 ? hint : (n * 4 + 1024);
    if cap < 256 { cap = 256; }
    while cap <= 268435456 {
        u8* dst = alloc<u8>(cap);
        i32 srcused = 0;
        i32 dstused = 0;
        i32 r = inflate(src, n, dst, cap, &srcused, &dstused);
        if r == 0 { *outlen = dstused; return dst; }
        free(dst);
        cap = cap * 2;   // grow (error may be output overflow)
    }
    return null;
}

// Raw input bytes of a string (UTF-8) or Buffer; heap buffer, caller frees.
private u8* zlib_input(VM* vm, Value data, i32* outlen) {
    if value_is_array(data) {
        JsObject* b = value_as_object(data);
        i32 n = b.elen;
        u8* buf = alloc<u8>(n > 0 ? n : 1);
        for i32 i = 0; i < n; i++ { *(buf + i) = cast(u8, buf_byte(b, i)); }
        *outlen = n;
        return buf;
    }
    Value s = js_to_string_value(vm, data);
    vm_push(vm, s);
    str_buf sb;
    str_buf_init(&sb);
    str_to_bytes(&sb, sview(s), ENC_UTF8);
    i32 n = sb.len;
    u8* buf = alloc<u8>(n > 0 ? n : 1);
    if n > 0 { memcpy(buf, sb.data, cast(i64, n)); }
    str_buf_free(&sb);
    vm_pop(vm);
    *outlen = n;
    return buf;
}

private Value nat_zlib_deflate_raw(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    i32 inlen = 0;
    u8* in = zlib_input(vm, arg_at(args, argc, 0), &inlen);
    i32 outlen = 0;
    u8* out = zlib_deflate_raw(in, inlen, &outlen);
    free(in);
    if out == null { vm_throw_error(vm, ERR_ERROR, "deflate failed"); return value_undefined(); }
    Value r = buf_from_bytes(vm, out, outlen);
    free(out);
    return r;
}

private Value nat_zlib_inflate_raw(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    i32 inlen = 0;
    u8* in = zlib_input(vm, arg_at(args, argc, 0), &inlen);
    i32 outlen = 0;
    u8* out = zlib_inflate_raw(in, inlen, 0, &outlen);
    free(in);
    if out == null { vm_throw_error(vm, ERR_ERROR, "incorrect data check"); return value_undefined(); }
    Value r = buf_from_bytes(vm, out, outlen);
    free(out);
    return r;
}

private Value nat_zlib_deflate(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    i32 inlen = 0;
    u8* in = zlib_input(vm, arg_at(args, argc, 0), &inlen);
    i32 rawlen = 0;
    u8* raw = zlib_deflate_raw(in, inlen, &rawlen);
    if raw == null { free(in); vm_throw_error(vm, ERR_ERROR, "deflate failed"); return value_undefined(); }
    u32 adler = zlib_adler32(in, inlen);
    free(in);
    i32 total = rawlen + 6;
    u8* out = alloc<u8>(total);
    *(out) = 0x78;
    *(out + 1) = 0x9C;
    memcpy(out + 2, raw, cast(i64, rawlen));
    free(raw);
    *(out + 2 + rawlen) = cast(u8, (adler >> 24) & 0xFF);
    *(out + 3 + rawlen) = cast(u8, (adler >> 16) & 0xFF);
    *(out + 4 + rawlen) = cast(u8, (adler >> 8) & 0xFF);
    *(out + 5 + rawlen) = cast(u8, adler & 0xFF);
    Value r = buf_from_bytes(vm, out, total);
    free(out);
    return r;
}

private Value nat_zlib_inflate(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    i32 inlen = 0;
    u8* in = zlib_input(vm, arg_at(args, argc, 0), &inlen);
    if inlen < 6 { free(in); vm_throw_error(vm, ERR_ERROR, "incorrect header check"); return value_undefined(); }
    // skip the 2-byte zlib header; DEFLATE's end marker stops before the
    // 4-byte Adler trailer
    i32 outlen = 0;
    u8* out = zlib_inflate_raw(in + 2, inlen - 2, 0, &outlen);
    free(in);
    if out == null { vm_throw_error(vm, ERR_ERROR, "incorrect data check"); return value_undefined(); }
    Value r = buf_from_bytes(vm, out, outlen);
    free(out);
    return r;
}

private Value nat_zlib_gzip(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    i32 inlen = 0;
    u8* in = zlib_input(vm, arg_at(args, argc, 0), &inlen);
    i32 rawlen = 0;
    u8* raw = zlib_deflate_raw(in, inlen, &rawlen);
    if raw == null { free(in); vm_throw_error(vm, ERR_ERROR, "gzip failed"); return value_undefined(); }
    u32 crc = zlib_crc32(in, inlen);
    u32 isize = cast(u32, inlen);
    free(in);
    i32 total = 10 + rawlen + 8;
    u8* out = alloc<u8>(total);
    memset(cast(u8*, out), 0, cast(i64, total));
    *(out) = 0x1F;
    *(out + 1) = 0x8B;
    *(out + 2) = 0x08;   // CM = deflate
    // FLG (3), MTIME (4-7) = 0, XFL (8) = 0 already zeroed
    *(out + 9) = 0xFF;   // OS = unknown
    memcpy(out + 10, raw, cast(i64, rawlen));
    free(raw);
    i32 tp = 10 + rawlen;
    *(out + tp) = cast(u8, crc & 0xFF);
    *(out + tp + 1) = cast(u8, (crc >> 8) & 0xFF);
    *(out + tp + 2) = cast(u8, (crc >> 16) & 0xFF);
    *(out + tp + 3) = cast(u8, (crc >> 24) & 0xFF);
    *(out + tp + 4) = cast(u8, isize & 0xFF);
    *(out + tp + 5) = cast(u8, (isize >> 8) & 0xFF);
    *(out + tp + 6) = cast(u8, (isize >> 16) & 0xFF);
    *(out + tp + 7) = cast(u8, (isize >> 24) & 0xFF);
    Value r = buf_from_bytes(vm, out, total);
    free(out);
    return r;
}

private Value nat_zlib_gunzip(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    i32 n = 0;
    u8* src = zlib_input(vm, arg_at(args, argc, 0), &n);
    if n < 18 || *(src) != 0x1F || *(src + 1) != 0x8B || *(src + 2) != 0x08 {
        free(src);
        vm_throw_error(vm, ERR_ERROR, "incorrect header check");
        return value_undefined();
    }
    u8 flg = *(src + 3);
    i32 pos = 10;
    if (flg & 4) != 0 {   // FEXTRA
        i32 xlen = cast(i32, *(src + pos)) | (cast(i32, *(src + pos + 1)) << 8);
        pos += 2 + xlen;
    }
    if (flg & 8) != 0 { while pos < n && *(src + pos) != 0 { pos++; } pos++; }    // FNAME
    if (flg & 16) != 0 { while pos < n && *(src + pos) != 0 { pos++; } pos++; }   // FCOMMENT
    if (flg & 2) != 0 { pos += 2; }                                              // FHCRC
    i32 isize = cast(i32, *(src + n - 4)) | (cast(i32, *(src + n - 3)) << 8)
        | (cast(i32, *(src + n - 2)) << 16) | (cast(i32, *(src + n - 1)) << 24);
    i32 deflate_len = n - pos - 8;
    i32 outlen = 0;
    u8* out = null;
    if deflate_len > 0 && pos < n { out = zlib_inflate_raw(src + pos, deflate_len, isize, &outlen); }
    free(src);
    if out == null { vm_throw_error(vm, ERR_ERROR, "incorrect data check"); return value_undefined(); }
    Value r = buf_from_bytes(vm, out, outlen);
    free(out);
    return r;
}

private JsObject* build_zlib_module(VM* vm) {
    JsObject* mod;
    JsObject* ns = new_node_module(vm, &mod);
    def_node_export(vm, mod, ns, "deflateRawSync", &nat_zlib_deflate_raw);
    def_node_export(vm, mod, ns, "inflateRawSync", &nat_zlib_inflate_raw);
    def_node_export(vm, mod, ns, "deflateSync", &nat_zlib_deflate);
    def_node_export(vm, mod, ns, "inflateSync", &nat_zlib_inflate);
    def_node_export(vm, mod, ns, "gzipSync", &nat_zlib_gzip);
    def_node_export(vm, mod, ns, "gunzipSync", &nat_zlib_gunzip);
    def_node_export(vm, mod, ns, "unzipSync", &nat_zlib_gunzip);
    return ns;
}

// --- core-module forms of globals (process / buffer / timers) ---------------

private void def_global_both(VM* vm, JsObject* mod, JsObject* ns, str name) {
    Value v = util_global(vm, name);
    props_set_desc(&mod.props, bi_atom(vm, name), v, PROP_DEFAULT);
    props_set_desc(&ns.props, bi_atom(vm, name), v, PROP_DEFAULT);
}

// `process` module: default is the process global; its own keys are also
// named exports (so `import { argv } from 'process'` works).
private JsObject* build_process_module(VM* vm) {
    Value proc = util_global(vm, "process");
    JsObject* ns = js_new_object(&vm.heap, null);
    gc_root(&vm.heap, value_cell(&ns.head));
    props_set_desc(&ns.props, bi_atom(vm, "default"), proc, PROP_DEFAULT);
    if value_is_object(proc) {
        JsObject* keys = vm_own_keys(vm, proc);
        vm_push(vm, value_cell(&keys.head));
        for i32 i = 0; i < keys.elen; i++ {
            Value kv = js_array_get(keys, i);
            u32 katom = atom_intern(&vm.atoms, sview(kv));
            Value v;
            if vm_get_prop_value(vm, proc, katom, &v) { props_set_desc(&ns.props, katom, v, PROP_DEFAULT); }
        }
        vm_pop(vm);
    }
    return ns;
}

private JsObject* build_buffer_module(VM* vm) {
    JsObject* mod = js_new_object(&vm.heap, vm.object_proto);
    vm_push(vm, value_cell(&mod.head));
    JsObject* ns = js_new_object(&vm.heap, null);
    gc_root(&vm.heap, value_cell(&ns.head));
    props_set_desc(&ns.props, bi_atom(vm, "default"), value_cell(&mod.head), PROP_DEFAULT);
    def_global_both(vm, mod, ns, "Buffer");
    vm_pop(vm);
    return ns;
}

private JsObject* build_timers_module(VM* vm) {
    JsObject* mod = js_new_object(&vm.heap, vm.object_proto);
    vm_push(vm, value_cell(&mod.head));
    JsObject* ns = js_new_object(&vm.heap, null);
    gc_root(&vm.heap, value_cell(&ns.head));
    props_set_desc(&ns.props, bi_atom(vm, "default"), value_cell(&mod.head), PROP_DEFAULT);
    def_global_both(vm, mod, ns, "setTimeout");
    def_global_both(vm, mod, ns, "clearTimeout");
    def_global_both(vm, mod, ns, "setInterval");
    def_global_both(vm, mod, ns, "clearInterval");
    def_global_both(vm, mod, ns, "queueMicrotask");
    vm_pop(vm);
    return ns;
}

// Returns the namespace of the named built-in module, or null. `name` has
// any `node:` prefix already stripped by the caller.
JsObject* builtins_node_module(VM* vm, str name) {
    if str_equal(name, "path") {
        if vm.node_path_ns == null { vm.node_path_ns = build_path_module(vm); }
        return vm.node_path_ns;
    }
    if str_equal(name, "fs") {
        if vm.node_fs_ns == null { vm.node_fs_ns = build_fs_module(vm); }
        return vm.node_fs_ns;
    }
    if str_equal(name, "fs/promises") {
        return builtins_fs_promises_module(vm);
    }
    if str_equal(name, "os") {
        if vm.node_os_ns == null { vm.node_os_ns = build_os_module(vm); }
        return vm.node_os_ns;
    }
    if str_equal(name, "events") {
        if vm.node_events_ns == null { vm.node_events_ns = build_events_module(vm); }
        return vm.node_events_ns;
    }
    if str_equal(name, "util") {
        if vm.node_util_ns == null { vm.node_util_ns = build_util_module(vm); }
        return vm.node_util_ns;
    }
    if str_equal(name, "crypto") {
        if vm.node_crypto_ns == null { vm.node_crypto_ns = build_crypto_module(vm); }
        return vm.node_crypto_ns;
    }
    if str_equal(name, "zlib") {
        if vm.node_zlib_ns == null { vm.node_zlib_ns = build_zlib_module(vm); }
        return vm.node_zlib_ns;
    }
    if str_equal(name, "process") {
        if vm.node_process_ns == null { vm.node_process_ns = build_process_module(vm); }
        return vm.node_process_ns;
    }
    if str_equal(name, "buffer") {
        if vm.node_buffer_ns == null { vm.node_buffer_ns = build_buffer_module(vm); }
        return vm.node_buffer_ns;
    }
    if str_equal(name, "timers") {
        if vm.node_timers_ns == null { vm.node_timers_ns = build_timers_module(vm); }
        return vm.node_timers_ns;
    }
    return null;
}

// --- URLSearchParams --------------------------------------------------------
//
// Ordered [name, value] string pairs in a hidden "%pairs" JS array.

private bool usp_unreserved(u8 c) {
    return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')
        || c == '*' || c == '-' || c == '.' || c == '_';
}
private void usp_encode(str_buf* out, str s) {
    str hexd = "0123456789ABCDEF";
    for i32 i = 0; i < s.len; i++ {
        u8 c = *(s.data + i);
        if c == ' ' { str_buf_add_byte(out, cast(u8, '+')); }
        else if usp_unreserved(c) { str_buf_add_byte(out, c); }
        else {
            str_buf_add_byte(out, cast(u8, '%'));
            str_buf_add_byte(out, *(hexd.data + (c >> 4)));
            str_buf_add_byte(out, *(hexd.data + (c & 0xF)));
        }
    }
}
private void usp_decode(str_buf* out, str s) {
    i32 i = 0;
    while i < s.len {
        u8 c = *(s.data + i);
        if c == '+' { str_buf_add_byte(out, cast(u8, ' ')); i++; }
        else if c == '%' && i + 2 < s.len {
            i32 hi = hex_val(*(s.data + i + 1));
            i32 lo = hex_val(*(s.data + i + 2));
            if hi >= 0 && lo >= 0 { str_buf_add_byte(out, cast(u8, (hi << 4) | lo)); i += 3; }
            else { str_buf_add_byte(out, c); i++; }
        } else { str_buf_add_byte(out, c); i++; }
    }
}

private JsObject* usp_pairs(VM* vm, Value thisv) {
    if !value_is_object(thisv) { return null; }
    Value p;
    if js_get_prop(value_as_object(thisv), bi_atom(vm, "%pairs"), &p) && value_is_array(p) {
        return value_as_object(p);
    }
    return null;
}

// Appends [name, val]; `pairs` and both values must be reachable/rooted.
private void usp_push_pair(VM* vm, JsObject* pairs, Value name, Value val) {
    JsObject* pair = js_new_array(&vm.heap, vm.array_proto);
    js_array_set(pairs, pairs.elen, value_cell(&pair.head));
    js_array_set(pair, 0, name);
    js_array_set(pair, 1, val);
}

private JsObject* usp_new(VM* vm) {
    JsObject* o = js_new_object(&vm.heap, vm.usp_proto);
    vm_push(vm, value_cell(&o.head));
    JsObject* pairs = js_new_array(&vm.heap, vm.array_proto);
    props_set_desc(&o.props, bi_atom(vm, "%pairs"), value_cell(&pairs.head), 0);
    vm_pop(vm);
    return o;
}

private void usp_parse_query(VM* vm, JsObject* pairs, str q) {
    i32 i = 0;
    while i < q.len {
        i32 start = i;
        while i < q.len && *(q.data + i) != '&' { i++; }
        str seg;
        seg.data = q.data + start;
        seg.len = i - start;
        if seg.len > 0 {
            i32 eq = -1;
            for i32 j = 0; j < seg.len; j++ { if *(seg.data + j) == '=' { eq = j; break; } }
            str k;
            str v;
            if eq < 0 { k = seg; v.data = seg.data; v.len = 0; }
            else { k.data = seg.data; k.len = eq; v.data = seg.data + eq + 1; v.len = seg.len - eq - 1; }
            str_buf kb;
            str_buf_init(&kb);
            usp_decode(&kb, k);
            Value kv = new_str(vm, str_buf_to_str(&kb));
            str_buf_free(&kb);
            vm_push(vm, kv);
            str_buf vb;
            str_buf_init(&vb);
            usp_decode(&vb, v);
            Value vv = new_str(vm, str_buf_to_str(&vb));
            str_buf_free(&vb);
            vm_push(vm, vv);
            usp_push_pair(vm, pairs, kv, vv);
            vm_pop(vm);
            vm_pop(vm);
        }
        i++;
    }
}

// Fills an existing USP object's pairs from an init value (string/array/
// object/URLSearchParams). `o` must be rooted by the caller.
private void usp_init_from(VM* vm, JsObject* o, Value init) {
    JsObject* pairs = usp_pairs(vm, value_cell(&o.head));
    if value_is_string(init) {
        str q = sview(init);
        if q.len > 0 && *(q.data) == '?' { q.data = q.data + 1; q.len = q.len - 1; }
        usp_parse_query(vm, pairs, q);
    } else if value_is_array(init) {
        JsObject* a = value_as_object(init);
        for i32 i = 0; i < a.elen; i++ {
            Value e = js_array_get(a, i);
            if value_is_array(e) {
                JsObject* ep = value_as_object(e);
                Value k = js_to_string_value(vm, js_array_get(ep, 0));
                vm_push(vm, k);
                Value v = js_to_string_value(vm, js_array_get(ep, 1));
                vm_push(vm, v);
                usp_push_pair(vm, pairs, k, v);
                vm_pop(vm);
                vm_pop(vm);
            }
        }
    } else if value_is_object(init) {
        JsObject* other = usp_pairs(vm, init);
        if other != null {
            for i32 i = 0; i < other.elen; i++ {
                JsObject* pair = value_as_object(js_array_get(other, i));
                usp_push_pair(vm, pairs, js_array_get(pair, 0), js_array_get(pair, 1));
            }
        } else {
            JsObject* keys = vm_own_keys(vm, init);
            vm_push(vm, value_cell(&keys.head));
            for i32 i = 0; i < keys.elen; i++ {
                Value kk = js_array_get(keys, i);
                vm_push(vm, kk);
                Value vv;
                if vm_get_prop_value(vm, init, atom_intern(&vm.atoms, sview(kk)), &vv) {
                    Value vs = js_to_string_value(vm, vv);
                    vm_push(vm, vs);
                    usp_push_pair(vm, pairs, kk, vs);
                    vm_pop(vm);
                }
                vm_pop(vm);
            }
            vm_pop(vm);
        }
    }
}

private Value nat_usp_ctor(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    JsObject* o = usp_new(vm);
    vm_push(vm, value_cell(&o.head));
    usp_init_from(vm, o, arg_at(args, argc, 0));
    vm_pop(vm);
    return value_cell(&o.head);
}

private Value nat_usp_get(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    Value namev = js_to_string_value(vm, arg_at(args, argc, 0));
    vm_push(vm, namev);
    JsObject* pairs = usp_pairs(vm, thisv);
    Value r = value_null();
    if pairs != null {
        for i32 i = 0; i < pairs.elen; i++ {
            JsObject* pair = value_as_object(js_array_get(pairs, i));
            if js_strict_eq(js_array_get(pair, 0), namev) { r = js_array_get(pair, 1); break; }
        }
    }
    vm_pop(vm);
    return r;
}

private Value nat_usp_getall(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    Value namev = js_to_string_value(vm, arg_at(args, argc, 0));
    vm_push(vm, namev);
    JsObject* out = js_new_array(&vm.heap, vm.array_proto);
    vm_push(vm, value_cell(&out.head));
    JsObject* pairs = usp_pairs(vm, thisv);
    if pairs != null {
        i32 n = 0;
        for i32 i = 0; i < pairs.elen; i++ {
            JsObject* pair = value_as_object(js_array_get(pairs, i));
            if js_strict_eq(js_array_get(pair, 0), namev) { js_array_set(out, n, js_array_get(pair, 1)); n++; }
        }
    }
    Value r = value_cell(&out.head);
    vm_pop(vm);
    vm_pop(vm);
    return r;
}

private Value nat_usp_has(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    Value namev = js_to_string_value(vm, arg_at(args, argc, 0));
    vm_push(vm, namev);
    JsObject* pairs = usp_pairs(vm, thisv);
    bool found = false;
    if pairs != null {
        for i32 i = 0; i < pairs.elen; i++ {
            JsObject* pair = value_as_object(js_array_get(pairs, i));
            if js_strict_eq(js_array_get(pair, 0), namev) { found = true; break; }
        }
    }
    vm_pop(vm);
    return value_bool(found);
}

private Value nat_usp_append(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    Value k = js_to_string_value(vm, arg_at(args, argc, 0));
    vm_push(vm, k);
    Value v = js_to_string_value(vm, arg_at(args, argc, 1));
    vm_push(vm, v);
    JsObject* pairs = usp_pairs(vm, thisv);
    if pairs != null { usp_push_pair(vm, pairs, k, v); }
    vm_pop(vm);
    vm_pop(vm);
    return value_undefined();
}

// Removes every pair with `name` from the pairs array (compacting in place).
private void usp_remove(JsObject* pairs, Value name) {
    i32 w = 0;
    for i32 i = 0; i < pairs.elen; i++ {
        Value e = js_array_get(pairs, i);
        JsObject* pair = value_as_object(e);
        if !js_strict_eq(js_array_get(pair, 0), name) {
            js_array_set(pairs, w, e);
            w++;
        }
    }
    js_array_set_length(pairs, w);
}

private Value nat_usp_delete(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    Value namev = js_to_string_value(vm, arg_at(args, argc, 0));
    vm_push(vm, namev);
    JsObject* pairs = usp_pairs(vm, thisv);
    if pairs != null { usp_remove(pairs, namev); }
    vm_pop(vm);
    return value_undefined();
}

private Value nat_usp_set(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    Value k = js_to_string_value(vm, arg_at(args, argc, 0));
    vm_push(vm, k);
    Value v = js_to_string_value(vm, arg_at(args, argc, 1));
    vm_push(vm, v);
    JsObject* pairs = usp_pairs(vm, thisv);
    if pairs != null {
        // set the first matching pair in place (preserving position) and
        // drop the rest; append if none matched (WHATWG set semantics).
        i32 first = -1;
        for i32 i = 0; i < pairs.elen; i++ {
            if js_strict_eq(js_array_get(value_as_object(js_array_get(pairs, i)), 0), k) { first = i; break; }
        }
        if first < 0 {
            usp_push_pair(vm, pairs, k, v);
        } else {
            js_array_set(value_as_object(js_array_get(pairs, first)), 1, v);
            i32 w = first + 1;
            for i32 i = first + 1; i < pairs.elen; i++ {
                Value e = js_array_get(pairs, i);
                if !js_strict_eq(js_array_get(value_as_object(e), 0), k) { js_array_set(pairs, w, e); w++; }
            }
            js_array_set_length(pairs, w);
        }
    }
    vm_pop(vm);
    vm_pop(vm);
    return value_undefined();
}

private Value nat_usp_tostring(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    str_buf out;
    str_buf_init(&out);
    JsObject* pairs = usp_pairs(vm, thisv);
    if pairs != null {
        for i32 i = 0; i < pairs.elen; i++ {
            if i > 0 { str_buf_add_byte(&out, cast(u8, '&')); }
            JsObject* pair = value_as_object(js_array_get(pairs, i));
            usp_encode(&out, sview(js_array_get(pair, 0)));
            str_buf_add_byte(&out, cast(u8, '='));
            usp_encode(&out, sview(js_array_get(pair, 1)));
        }
    }
    Value r = new_str(vm, str_buf_to_str(&out));
    str_buf_free(&out);
    return r;
}

private Value nat_usp_sort(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    JsObject* pairs = usp_pairs(vm, thisv);
    if pairs != null {
        // stable insertion sort by key bytes
        for i32 i = 1; i < pairs.elen; i++ {
            Value cur = js_array_get(pairs, i);
            str ck = sview(js_array_get(value_as_object(cur), 0));
            i32 j = i - 1;
            while j >= 0 {
                str jk = sview(js_array_get(value_as_object(js_array_get(pairs, j)), 0));
                if js_str_cmp(jk, ck) <= 0 { break; }
                js_array_set(pairs, j + 1, js_array_get(pairs, j));
                j--;
            }
            js_array_set(pairs, j + 1, cur);
        }
    }
    return value_undefined();
}

private Value nat_usp_foreach(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    Value cb = arg_at(args, argc, 0);
    if !value_is_callable(cb) { return value_undefined(); }
    JsObject* pairs = usp_pairs(vm, thisv);
    if pairs == null { return value_undefined(); }
    for i32 i = 0; i < pairs.elen; i++ {
        JsObject* pair = value_as_object(js_array_get(pairs, i));
        Value[3] cargs;
        cargs[0] = js_array_get(pair, 1);
        cargs[1] = js_array_get(pair, 0);
        cargs[2] = thisv;
        ignore vm_call_value(vm, cb, arg_at(args, argc, 1), &cargs[0], 3);
        if vm.has_pending { break; }
    }
    return value_undefined();
}

private Value nat_usp_size(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    JsObject* pairs = usp_pairs(vm, thisv);
    if pairs == null { return value_number(0.0); }
    return value_number(cast(f64, pairs.elen));
}

// Builds an array of keys / values / [k,v] pairs, then an index iterator.
private Value usp_iter(VM* vm, Value thisv, i32 mode) {
    JsObject* out = js_new_array(&vm.heap, vm.array_proto);
    vm_push(vm, value_cell(&out.head));
    JsObject* pairs = usp_pairs(vm, thisv);
    if pairs != null {
        for i32 i = 0; i < pairs.elen; i++ {
            JsObject* pair = value_as_object(js_array_get(pairs, i));
            if mode == 0 { js_array_set(out, i, js_array_get(pair, 0)); }
            else if mode == 1 { js_array_set(out, i, js_array_get(pair, 1)); }
            else {
                JsObject* e = js_new_array(&vm.heap, vm.array_proto);
                js_array_set(out, i, value_cell(&e.head));
                js_array_set(e, 0, js_array_get(pair, 0));
                js_array_set(e, 1, js_array_get(pair, 1));
            }
        }
    }
    Value it = make_index_iterator(vm, value_cell(&out.head), 0);
    vm_pop(vm);
    return it;
}
private Value nat_usp_keys(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    return usp_iter(as_vm(vmp), thisv, 0);
}
private Value nat_usp_values(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    return usp_iter(as_vm(vmp), thisv, 1);
}
private Value nat_usp_entries(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    return usp_iter(as_vm(vmp), thisv, 2);
}

// --- URL --------------------------------------------------------------------

struct UrlParts {
    str scheme; str user; str pass; str host; str port;
    str path; str query; str hash;
    bool has_authority; bool has_query; bool has_hash;
}

private bool url_scheme_char(u8 c) {
    return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')
        || c == '+' || c == '.' || c == '-';
}
private bool is_origin_scheme(str s) {
    return str_equal(s, "http") || str_equal(s, "https") || str_equal(s, "ws")
        || str_equal(s, "wss") || str_equal(s, "ftp");
}
private bool is_default_port(str scheme, str port) {
    if port.len == 0 { return false; }
    i32 pn = 0;
    for i32 i = 0; i < port.len; i++ {
        u8 c = *(port.data + i);
        if c < '0' || c > '9' { return false; }
        pn = pn * 10 + cast(i32, c - '0');
    }
    if str_equal(scheme, "http") || str_equal(scheme, "ws") { return pn == 80; }
    if str_equal(scheme, "https") || str_equal(scheme, "wss") { return pn == 443; }
    if str_equal(scheme, "ftp") { return pn == 21; }
    return false;
}

// Parses an absolute URL (must start with `scheme:`). Views into `s`.
private bool parse_absolute(str s, UrlParts* out) {
    out.user.len = 0; out.pass.len = 0; out.host.len = 0; out.port.len = 0;
    out.path.len = 0; out.query.len = 0; out.hash.len = 0;
    out.user.data = s.data; out.pass.data = s.data; out.host.data = s.data;
    out.port.data = s.data; out.path.data = s.data; out.query.data = s.data; out.hash.data = s.data;
    out.has_authority = false; out.has_query = false; out.has_hash = false;
    if s.len == 0 { return false; }
    u8 c0 = *(s.data);
    if !((c0 >= 'A' && c0 <= 'Z') || (c0 >= 'a' && c0 <= 'z')) { return false; }
    i32 colon = -1;
    i32 j = 1;
    while j < s.len {
        u8 c = *(s.data + j);
        if c == ':' { colon = j; break; }
        if !url_scheme_char(c) { break; }
        j++;
    }
    if colon < 0 { return false; }
    out.scheme.data = s.data;
    out.scheme.len = colon;
    i32 i = colon + 1;
    if i + 1 < s.len && *(s.data + i) == '/' && *(s.data + i + 1) == '/' {
        out.has_authority = true;
        i += 2;
        i32 astart = i;
        while i < s.len {
            u8 c = *(s.data + i);
            if c == '/' || c == '?' || c == '#' { break; }
            i++;
        }
        str auth;
        auth.data = s.data + astart;
        auth.len = i - astart;
        i32 at = -1;
        for i32 k = 0; k < auth.len; k++ { if *(auth.data + k) == '@' { at = k; } }
        str hostport;
        if at >= 0 {
            str ui;
            ui.data = auth.data;
            ui.len = at;
            i32 uc = -1;
            for i32 k = 0; k < ui.len; k++ { if *(ui.data + k) == ':' { uc = k; break; } }
            if uc < 0 { out.user = ui; }
            else {
                out.user.data = ui.data; out.user.len = uc;
                out.pass.data = ui.data + uc + 1; out.pass.len = ui.len - uc - 1;
            }
            hostport.data = auth.data + at + 1;
            hostport.len = auth.len - at - 1;
        } else { hostport = auth; }
        i32 pc = -1;
        for i32 k = 0; k < hostport.len; k++ { if *(hostport.data + k) == ':' { pc = k; } }
        if pc < 0 { out.host = hostport; }
        else {
            out.host.data = hostport.data; out.host.len = pc;
            out.port.data = hostport.data + pc + 1; out.port.len = hostport.len - pc - 1;
        }
    }
    i32 pstart = i;
    while i < s.len && *(s.data + i) != '?' && *(s.data + i) != '#' { i++; }
    out.path.data = s.data + pstart;
    out.path.len = i - pstart;
    if i < s.len && *(s.data + i) == '?' {
        out.has_query = true;
        i++;
        i32 qstart = i;
        while i < s.len && *(s.data + i) != '#' { i++; }
        out.query.data = s.data + qstart;
        out.query.len = i - qstart;
    }
    if i < s.len && *(s.data + i) == '#' {
        out.has_hash = true;
        out.hash.data = s.data + i + 1;
        out.hash.len = s.len - i - 1;
    }
    return true;
}

private void url_append_authority(str_buf* b, UrlParts* p, str port) {
    if p.user.len > 0 || p.pass.len > 0 {
        str_buf_add(b, p.user);
        if p.pass.len > 0 { str_buf_add_byte(b, cast(u8, ':')); str_buf_add(b, p.pass); }
        str_buf_add_byte(b, cast(u8, '@'));
    }
    str_buf_add(b, p.host);
    if port.len > 0 { str_buf_add_byte(b, cast(u8, ':')); str_buf_add(b, port); }
}

private JsObject* build_url(VM* vm, UrlParts* p) {
    JsObject* o = js_new_object(&vm.heap, vm.url_proto);
    vm_push(vm, value_cell(&o.head));
    str port = p.port;
    if is_default_port(p.scheme, port) { port.len = 0; }

    str_buf b;
    str_buf_init(&b);
    str_buf_add(&b, p.scheme);
    str_buf_add_byte(&b, cast(u8, ':'));
    def_value_enum(vm, o, "protocol", new_str(vm, str_buf_to_str(&b)));
    str_buf_free(&b);

    def_value_enum(vm, o, "username", new_str(vm, p.user));
    def_value_enum(vm, o, "password", new_str(vm, p.pass));
    def_value_enum(vm, o, "hostname", new_str(vm, p.host));
    def_value_enum(vm, o, "port", new_str(vm, port));

    str_buf hb;
    str_buf_init(&hb);
    str_buf_add(&hb, p.host);
    if port.len > 0 { str_buf_add_byte(&hb, cast(u8, ':')); str_buf_add(&hb, port); }
    def_value_enum(vm, o, "host", new_str(vm, str_buf_to_str(&hb)));
    str_buf_free(&hb);

    str pathname = p.path;
    if p.has_authority && p.path.len == 0 { pathname = "/"; }
    def_value_enum(vm, o, "pathname", new_str(vm, pathname));

    str_buf sb;
    str_buf_init(&sb);
    if p.has_query { str_buf_add_byte(&sb, cast(u8, '?')); str_buf_add(&sb, p.query); }
    def_value_enum(vm, o, "search", new_str(vm, str_buf_to_str(&sb)));
    str_buf_free(&sb);

    str_buf fb;
    str_buf_init(&fb);
    if p.has_hash { str_buf_add_byte(&fb, cast(u8, '#')); str_buf_add(&fb, p.hash); }
    def_value_enum(vm, o, "hash", new_str(vm, str_buf_to_str(&fb)));
    str_buf_free(&fb);

    str_buf ob;
    str_buf_init(&ob);
    if is_origin_scheme(p.scheme) {
        str_buf_add(&ob, p.scheme);
        str_buf_add(&ob, "://");
        str_buf_add(&ob, p.host);
        if port.len > 0 { str_buf_add_byte(&ob, cast(u8, ':')); str_buf_add(&ob, port); }
    } else { str_buf_add(&ob, "null"); }
    def_value_enum(vm, o, "origin", new_str(vm, str_buf_to_str(&ob)));
    str_buf_free(&ob);

    str_buf hf;
    str_buf_init(&hf);
    str_buf_add(&hf, p.scheme);
    str_buf_add_byte(&hf, cast(u8, ':'));
    if p.has_authority { str_buf_add(&hf, "//"); url_append_authority(&hf, p, port); }
    str_buf_add(&hf, pathname);
    if p.has_query { str_buf_add_byte(&hf, cast(u8, '?')); str_buf_add(&hf, p.query); }
    if p.has_hash { str_buf_add_byte(&hf, cast(u8, '#')); str_buf_add(&hf, p.hash); }
    def_value_enum(vm, o, "href", new_str(vm, str_buf_to_str(&hf)));
    str_buf_free(&hf);

    JsObject* sp = usp_new(vm);
    vm_push(vm, value_cell(&sp.head));
    usp_parse_query(vm, usp_pairs(vm, value_cell(&sp.head)), p.query);
    def_value_enum(vm, o, "searchParams", value_cell(&sp.head));
    vm_pop(vm);

    vm_pop(vm);
    return o;
}

private Value nat_url_tostring(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    Value h;
    if value_is_object(thisv) && js_get_prop(value_as_object(thisv), bi_atom(vm, "href"), &h) { return h; }
    return new_str(vm, "");
}

// Collapses `.`/`..`/duplicate `/` in a URL path (always `/`-separated),
// preserving a leading slash and a trailing slash.
private void url_path_norm(str_buf* out, str p) {
    bool abs = p.len > 0 && *(p.data) == '/';
    Vec<str> segs = vec_new<str>(8);
    i32 i = 0;
    while i < p.len {
        while i < p.len && *(p.data + i) == '/' { i++; }
        i32 start = i;
        while i < p.len && *(p.data + i) != '/' { i++; }
        str seg;
        seg.data = p.data + start;
        seg.len = i - start;
        if seg.len == 0 { }
        else if seg.len == 1 && *(seg.data) == '.' { }
        else if seg.len == 2 && *(seg.data) == '.' && *(seg.data + 1) == '.' {
            if segs.len > 0 { segs.len = segs.len - 1; }
        }
        else { vec_push(&segs, seg); }
    }
    if abs { str_buf_add_byte(out, cast(u8, '/')); }
    for i32 k = 0; k < segs.len; k++ {
        if k > 0 { str_buf_add_byte(out, cast(u8, '/')); }
        str_buf_add(out, vec_get(&segs, k));
    }
    if p.len > 0 && *(p.data + p.len - 1) == '/' && segs.len > 0 { str_buf_add_byte(out, cast(u8, '/')); }
    vec_free(&segs);
}

private str url_heapcopy(str_buf* out) {
    str v = str_buf_to_str(out);
    u8* d = alloc<u8>(v.len > 0 ? v.len : 1);
    if v.len > 0 { memcpy(d, v.data, v.len); }
    str r;
    r.data = d;
    r.len = v.len;
    return r;
}

// Resolves `input` (a non-absolute reference) against base `bp`; returns a
// heap-allocated absolute URL string (caller frees .data).
private str resolve_relative(VM* vm, str input, UrlParts* bp) {
    str_buf out;
    str_buf_init(&out);
    str port = bp.port;
    bool two = input.len >= 2 && *(input.data) == '/' && *(input.data + 1) == '/';
    if two {
        str_buf_add(&out, bp.scheme);
        str_buf_add_byte(&out, cast(u8, ':'));
        str_buf_add(&out, input);
    } else if input.len > 0 && *(input.data) == '/' {
        str_buf_add(&out, bp.scheme); str_buf_add(&out, "://");
        url_append_authority(&out, bp, port);
        str_buf_add(&out, input);
    } else if input.len > 0 && *(input.data) == '?' {
        str_buf_add(&out, bp.scheme); str_buf_add(&out, "://");
        url_append_authority(&out, bp, port);
        str_buf_add(&out, bp.path);
        str_buf_add(&out, input);
    } else if input.len > 0 && *(input.data) == '#' {
        str_buf_add(&out, bp.scheme); str_buf_add(&out, "://");
        url_append_authority(&out, bp, port);
        str_buf_add(&out, bp.path);
        if bp.has_query { str_buf_add_byte(&out, cast(u8, '?')); str_buf_add(&out, bp.query); }
        str_buf_add(&out, input);
    } else {
        str_buf_add(&out, bp.scheme); str_buf_add(&out, "://");
        url_append_authority(&out, bp, port);
        i32 lastslash = -1;
        for i32 k = 0; k < bp.path.len; k++ { if *(bp.path.data + k) == '/' { lastslash = k; } }
        str_buf cb;
        str_buf_init(&cb);
        if lastslash >= 0 { str seg; seg.data = bp.path.data; seg.len = lastslash + 1; str_buf_add(&cb, seg); }
        else { str_buf_add_byte(&cb, cast(u8, '/')); }
        i32 ip = 0;
        while ip < input.len && *(input.data + ip) != '?' && *(input.data + ip) != '#' { ip++; }
        str ipath;
        ipath.data = input.data;
        ipath.len = ip;
        str_buf_add(&cb, ipath);
        str_buf nb;
        str_buf_init(&nb);
        url_path_norm(&nb, str_buf_to_str(&cb));
        str_buf_add(&out, str_buf_to_str(&nb));
        if ip < input.len { str rest; rest.data = input.data + ip; rest.len = input.len - ip; str_buf_add(&out, rest); }
        str_buf_free(&cb);
        str_buf_free(&nb);
    }
    str r = url_heapcopy(&out);
    str_buf_free(&out);
    return r;
}

private Value nat_url_ctor(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    Value inputv = js_to_string_value(vm, arg_at(args, argc, 0));
    vm_push(vm, inputv);
    UrlParts parts;
    if parse_absolute(sview(inputv), &parts) {
        JsObject* o = build_url(vm, &parts);
        vm_pop(vm);
        return value_cell(&o.head);
    }
    // relative reference — resolve against a base
    Value basev = arg_at(args, argc, 1);
    if value_is_undefined(basev) || value_is_null(basev) {
        vm_pop(vm);
        vm_throw_error(vm, ERR_TYPE, "Invalid URL");
        return value_undefined();
    }
    Value basestr = js_to_string_value(vm, basev);
    vm_push(vm, basestr);
    UrlParts bp;
    if !parse_absolute(sview(basestr), &bp) {
        vm_pop(vm);
        vm_pop(vm);
        vm_throw_error(vm, ERR_TYPE, "Invalid base URL");
        return value_undefined();
    }
    str resolved = resolve_relative(vm, sview(inputv), &bp);
    UrlParts rp;
    bool rok = parse_absolute(resolved, &rp);
    Value ret = value_undefined();
    if rok {
        JsObject* o = build_url(vm, &rp);
        ret = value_cell(&o.head);
    }
    free(resolved.data);
    vm_pop(vm);
    vm_pop(vm);
    if !rok { vm_throw_error(vm, ERR_TYPE, "Invalid URL"); }
    return ret;
}

private void url_install(VM* vm) {
    vm.url_proto = js_new_object(&vm.heap, vm.object_proto);
    JsNative* ctor = def_global_fn(vm, "URL", &nat_url_ctor);
    props_set_desc(&ctor.props, vm.atom_prototype, value_cell(&vm.url_proto.head), 0);
    link_ctor(vm, vm.url_proto, ctor);
    def_method(vm, vm.url_proto, "toString", &nat_url_tostring);
    def_method(vm, vm.url_proto, "toJSON", &nat_url_tostring);
}

private void usp_install(VM* vm) {
    vm.usp_proto = js_new_object(&vm.heap, vm.object_proto);
    JsNative* ctor = def_global_fn(vm, "URLSearchParams", &nat_usp_ctor);
    props_set_desc(&ctor.props, vm.atom_prototype, value_cell(&vm.usp_proto.head), 0);
    link_ctor(vm, vm.usp_proto, ctor);
    def_method(vm, vm.usp_proto, "get", &nat_usp_get);
    def_method(vm, vm.usp_proto, "getAll", &nat_usp_getall);
    def_method(vm, vm.usp_proto, "has", &nat_usp_has);
    def_method(vm, vm.usp_proto, "set", &nat_usp_set);
    def_method(vm, vm.usp_proto, "append", &nat_usp_append);
    def_method(vm, vm.usp_proto, "delete", &nat_usp_delete);
    def_method(vm, vm.usp_proto, "toString", &nat_usp_tostring);
    def_method(vm, vm.usp_proto, "sort", &nat_usp_sort);
    def_method(vm, vm.usp_proto, "forEach", &nat_usp_foreach);
    def_method(vm, vm.usp_proto, "keys", &nat_usp_keys);
    def_method(vm, vm.usp_proto, "values", &nat_usp_values);
    def_method(vm, vm.usp_proto, "entries", &nat_usp_entries);
    JsNative* it = js_new_native(&vm.heap, &nat_usp_entries, "[Symbol.iterator]");
    props_set_desc(&vm.usp_proto.props, vm_sym_iterator_id(vm), value_cell(&it.head), METHOD_ATTRS);
    def_accessor(vm, vm.usp_proto, "size", &nat_usp_size);
}

// --- Proxy + Reflect --------------------------------------------------------

private Value nat_proxy_ctor(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    Value target = arg_at(args, argc, 0);
    Value handler = arg_at(args, argc, 1);
    if !value_is_object(target) && !value_is_callable(target) {
        vm_throw_error(vm, ERR_TYPE, "Cannot create proxy with a non-object as target");
        return value_undefined();
    }
    if !value_is_object(handler) {
        vm_throw_error(vm, ERR_TYPE, "Cannot create proxy with a non-object as handler");
        return value_undefined();
    }
    JsObject* proto = null;
    if value_is_object(target) { proto = value_as_object(target).proto; }
    JsProxy* p = js_new_proxy(&vm.heap, proto, target, handler);
    return value_cell(&p.head);
}

// revoke() marks its captured proxy revoked; every later operation throws.
private Value nat_proxy_revoke(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    Value pv = value_as_native(callee).env0;
    if value_is_object(pv) {
        JsObject* o = value_as_object(pv);
        if (o.obj_flags & OBJF_PROXY) != 0 { o.obj_flags = o.obj_flags | OBJF_PROXY_REVOKED; }
    }
    return value_undefined();
}

// Proxy.revocable(target, handler) -> { proxy, revoke }.
private Value nat_proxy_revocable(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    Value target = arg_at(args, argc, 0);
    Value handler = arg_at(args, argc, 1);
    if (!value_is_object(target) && !value_is_callable(target)) || !value_is_object(handler) {
        vm_throw_error(vm, ERR_TYPE, "Cannot create proxy with a non-object as target or handler");
        return value_undefined();
    }
    JsObject* proto = null;
    if value_is_object(target) { proto = value_as_object(target).proto; }
    JsProxy* p = js_new_proxy(&vm.heap, proto, target, handler);
    Value pv = value_cell(&p.head);
    i32 rm = gc_root_mark(&vm.heap);
    gc_root(&vm.heap, pv);
    JsNative* revoke = js_new_native(&vm.heap, &nat_proxy_revoke, "revoke");
    revoke.env0 = pv;
    JsObject* result = js_new_object(&vm.heap, vm.object_proto);
    gc_root(&vm.heap, value_cell(&result.head));
    js_set_prop(result, bi_atom(vm, "proxy"), pv);
    js_set_prop(result, bi_atom(vm, "revoke"), value_cell(&revoke.head));
    gc_root_reset(&vm.heap, rm);
    return value_cell(&result.head);
}

// Reflect accepts any object-like receiver. Functions and natives are
// objects too: they carry their own property table and [[Prototype]], so
// they must not be rejected here.
private bool reflect_target(VM* vm, Value* args, i32 argc, str who, Value* out) {
    Value target = arg_at(args, argc, 0);
    if !value_is_object(target) && !value_is_function(target) && !value_is_native(target) {
        vm_throw_error(vm, ERR_TYPE, who);
        return false;
    }
    *out = target;
    return true;
}

// The receiver as a plain object, or null when it is a function/native.
private JsObject* reflect_obj(Value t) {
    return value_is_object(t) ? value_as_object(t) : null;
}

private Value nat_reflect_get(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    Value t;
    if !reflect_target(vm, args, argc, "Reflect.get called on non-object", &t) { return value_undefined(); }
    str sk;
    u32 a = reflect_key(vm, arg_at(args, argc, 1), &sk);
    Value out;
    ignore vm_get_prop_value(vm, t, a, &out);
    return out;
}

private Value nat_reflect_set(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    Value t;
    if !reflect_target(vm, args, argc, "Reflect.set called on non-object", &t) { return value_undefined(); }
    str sk;
    u32 a = reflect_key(vm, arg_at(args, argc, 1), &sk);
    bool ok = vm_set_prop_value(vm, t, a, arg_at(args, argc, 2));
    return value_bool(ok);
}

private Value nat_reflect_has(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    Value t;
    if !reflect_target(vm, args, argc, "Reflect.has called on non-object", &t) { return value_undefined(); }
    str sk;
    u32 a = reflect_key(vm, arg_at(args, argc, 1), &sk);
    JsObject* o = reflect_obj(t);
    if o == null { return value_bool(fn_has_prop(vm, t, a)); }
    bool r = (o.obj_flags & OBJF_PROXY) != 0 ? proxy_has(vm, cast(JsProxy*, o), a) : js_has_prop(o, a);
    return value_bool(r);
}

private Value nat_reflect_delete(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    Value t;
    if !reflect_target(vm, args, argc, "Reflect.deleteProperty called on non-object", &t) { return value_undefined(); }
    str sk;
    u32 a = reflect_key(vm, arg_at(args, argc, 1), &sk);
    JsObject* o = reflect_obj(t);
    if o == null {
        PropList* props = value_props(t);
        return value_bool(props != null ? props_remove(props, a) : false);
    }
    bool r = (o.obj_flags & OBJF_PROXY) != 0 ? proxy_delete(vm, cast(JsProxy*, o), a) : js_delete_prop(o, a);
    return value_bool(r);
}

private Value nat_reflect_getprototypeof(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    Value t;
    if !reflect_target(vm, args, argc, "Reflect.getPrototypeOf called on non-object", &t) { return value_undefined(); }
    // shares Object.getPrototypeOf, which resolves a function's [[Prototype]]
    return nat_object_getproto(vmp, callee, thisv, args, argc);
}

private Value nat_reflect_setprototypeof(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    Value t;
    if !reflect_target(vm, args, argc, "Reflect.setPrototypeOf called on non-object", &t) { return value_undefined(); }
    ignore nat_object_setproto(vmp, callee, thisv, args, argc);
    return value_bool(!vm.has_pending);
}

private Value nat_reflect_ownkeys(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    Value t;
    if !reflect_target(vm, args, argc, "Reflect.ownKeys called on non-object", &t) { return value_undefined(); }
    // for a proxy, the raw ownKeys trap result (strings + symbols); otherwise
    // every own key, non-enumerable included (unlike Object.keys)
    JsObject* o = reflect_obj(t);
    if o != null && (o.obj_flags & OBJF_PROXY) != 0 {
        return value_cell(&proxy_own_keys(vm, cast(JsProxy*, o)).head);
    }
    return nat_object_getownnames(vmp, callee, thisv, args, argc);
}

private Value nat_reflect_getownpropdesc(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    return nat_object_getownpropdesc(vmp, callee, thisv, args, argc);
}

private Value nat_reflect_defineproperty(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    Value t;
    if !reflect_target(vm, args, argc, "Reflect.defineProperty called on non-object", &t) { return value_undefined(); }
    ignore nat_object_defineproperty(vmp, callee, thisv, args, argc);
    return value_bool(!vm.has_pending);
}

// Elements of an array-like args list into a heap buffer (caller frees).
private i32 reflect_spread_args(VM* vm, Value listv, Value** out) {
    JsObject* a = null;
    if value_is_object(listv) { a = this_arraylike(vm, listv); }
    i32 n = a != null ? a.elen : 0;
    Value* av = alloc<Value>(n > 0 ? n : 1);
    for i32 i = 0; i < n; i++ { *(av + i) = js_array_get(a, i); }
    *out = av;
    return n;
}

private Value nat_reflect_apply(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    Value target = arg_at(args, argc, 0);
    if !value_is_callable(target) {
        vm_throw_error(vm, ERR_TYPE, "Reflect.apply target is not a function");
        return value_undefined();
    }
    Value thisArg = arg_at(args, argc, 1);
    Value* av;
    i32 n = reflect_spread_args(vm, arg_at(args, argc, 2), &av);
    Value r = vm_call_value(vm, target, thisArg, av, n);
    free(av);
    return r;
}

private Value nat_reflect_construct(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    Value target = arg_at(args, argc, 0);
    if !value_is_callable(target) {
        vm_throw_error(vm, ERR_TYPE, "Reflect.construct target is not a constructor");
        return value_undefined();
    }
    i32 rm = gc_root_mark(&vm.heap);
    JsObject* proto = vm.object_proto;
    Value pv;
    if vm_get_prop_value(vm, target, vm.atom_prototype, &pv) && value_is_object(pv) {
        proto = value_as_object(pv);
    }
    JsObject* inst = js_new_object(&vm.heap, proto);
    Value instv = value_cell(&inst.head);
    gc_root(&vm.heap, instv);
    Value* av;
    i32 n = reflect_spread_args(vm, arg_at(args, argc, 1), &av);
    // new.target is the explicit newTarget argument, or the target itself
    Value ntv = argc > 2 ? arg_at(args, argc, 2) : target;
    vm.pending_new_target = value_is_callable(ntv) ? ntv : target;
    Value res = vm_call_value(vm, target, instv, av, n);
    free(av);
    gc_root_reset(&vm.heap, rm);
    return value_is_reference(res) ? res : instv;
}

private void install_proxy_reflect(VM* vm) {
    JsNative* proxy_ctor = def_global_fn(vm, "Proxy", &nat_proxy_ctor);
    def_static(vm, proxy_ctor, "revocable", &nat_proxy_revocable);
    JsObject* reflect = js_new_object(&vm.heap, vm.object_proto);
    i32 rm = gc_root_mark(&vm.heap);
    gc_root(&vm.heap, value_cell(&reflect.head));   // keep alive across def_method allocs
    def_method(vm, reflect, "get", &nat_reflect_get);
    def_method(vm, reflect, "set", &nat_reflect_set);
    def_method(vm, reflect, "has", &nat_reflect_has);
    def_method(vm, reflect, "deleteProperty", &nat_reflect_delete);
    def_method(vm, reflect, "getPrototypeOf", &nat_reflect_getprototypeof);
    def_method(vm, reflect, "setPrototypeOf", &nat_reflect_setprototypeof);
    def_method(vm, reflect, "ownKeys", &nat_reflect_ownkeys);
    def_method(vm, reflect, "getOwnPropertyDescriptor", &nat_reflect_getownpropdesc);
    def_method(vm, reflect, "defineProperty", &nat_reflect_defineproperty);
    def_method(vm, reflect, "apply", &nat_reflect_apply);
    def_method(vm, reflect, "construct", &nat_reflect_construct);
    vm_set_global(vm, "Reflect", value_cell(&reflect.head));
    gc_root_reset(&vm.heap, rm);
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
    for i32 i = 1; i < ERR_KIND_COUNT; i++ {
        vm.error_protos[i] = js_new_object(&vm.heap, vm.error_protos[ERR_ERROR]);
    }

    // Object
    JsNative* object_ctor = def_global_fn(vm, "Object", &nat_object_ctor);
    props_set_desc(&object_ctor.props, vm.atom_prototype, value_cell(&vm.object_proto.head), 0);
    def_static(vm, object_ctor, "keys", &nat_object_keys);
    def_static(vm, object_ctor, "values", &nat_object_values);
    def_static(vm, object_ctor, "entries", &nat_object_entries);
    def_static(vm, object_ctor, "assign", &nat_object_assign);
    def_static(vm, object_ctor, "create", &nat_object_create);
    def_static(vm, object_ctor, "getPrototypeOf", &nat_object_getproto);
    def_static(vm, object_ctor, "setPrototypeOf", &nat_object_setproto);
    def_static(vm, object_ctor, "getOwnPropertyNames", &nat_object_getownnames);
    def_static(vm, object_ctor, "getOwnPropertySymbols", &nat_object_getownsymbols);
    def_static(vm, object_ctor, "fromEntries", &nat_object_fromentries);
    def_static(vm, object_ctor, "defineProperty", &nat_object_defineproperty);
    def_static(vm, object_ctor, "defineProperties", &nat_object_defineproperties);
    def_static(vm, object_ctor, "getOwnPropertyDescriptor", &nat_object_getownpropdesc);
    def_static(vm, object_ctor, "getOwnPropertyDescriptors", &nat_object_getownpropdescs);
    def_static(vm, object_ctor, "is", &nat_object_is);
    def_static(vm, object_ctor, "hasOwn", &nat_object_hasown);
    def_static(vm, object_ctor, "freeze", &nat_object_freeze);
    def_static(vm, object_ctor, "isFrozen", &nat_object_isfrozen);
    def_static(vm, object_ctor, "seal", &nat_object_seal);
    def_static(vm, object_ctor, "isSealed", &nat_object_issealed);
    def_static(vm, object_ctor, "preventExtensions", &nat_object_preventext);
    def_static(vm, object_ctor, "isExtensible", &nat_object_isextensible);
    def_method(vm, vm.object_proto, "hasOwnProperty", &nat_has_own);
    def_method(vm, vm.object_proto, "propertyIsEnumerable", &nat_property_is_enumerable);
    def_method(vm, vm.object_proto, "toString", &nat_object_tostring);

    // Array
    JsNative* array_ctor = def_global_fn(vm, "Array", &nat_array_ctor);
    props_set_desc(&array_ctor.props, vm.atom_prototype, value_cell(&vm.array_proto.head), 0);
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
    props_set_desc(&string_ctor.props, vm.atom_prototype, value_cell(&vm.string_proto.head), 0);
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
    props_set_desc(&number_ctor.props, vm.atom_prototype, value_cell(&vm.number_proto.head), 0);
    def_static(vm, number_ctor, "isInteger", &nat_num_isinteger);
    def_static(vm, number_ctor, "isFinite", &nat_num_isfinite);
    def_static(vm, number_ctor, "isSafeInteger", &nat_num_issafeinteger);
    def_static(vm, number_ctor, "isNaN", &nat_num_isnan);
    def_static(vm, number_ctor, "parseInt", &nat_parseint);
    def_static(vm, number_ctor, "parseFloat", &nat_parsefloat);
    // Numeric constants: spec attributes are all off (non-writable,
    // non-enumerable, non-configurable). MIN_VALUE is the smallest
    // positive denormal double.
    num_const(vm, number_ctor, "MAX_VALUE", 1.7976931348623157e+308);
    num_const(vm, number_ctor, "MIN_VALUE", 5.0e-324);
    num_const(vm, number_ctor, "MAX_SAFE_INTEGER", 9007199254740991.0);
    num_const(vm, number_ctor, "MIN_SAFE_INTEGER", -9007199254740991.0);
    num_const(vm, number_ctor, "EPSILON", 2.220446049250313e-16);
    num_const(vm, number_ctor, "POSITIVE_INFINITY", 1.0e308 * 10.0);
    num_const(vm, number_ctor, "NEGATIVE_INFINITY", -1.0e308 * 10.0);
    num_const(vm, number_ctor, "NaN", 0.0 / 0.0);
    def_method(vm, vm.number_proto, "toFixed", &nat_num_tofixed);
    def_method(vm, vm.number_proto, "toString", &nat_num_tostring);
    def_method(vm, vm.number_proto, "toExponential", &nat_num_toexponential);
    def_method(vm, vm.number_proto, "toPrecision", &nat_num_toprecision);
    def_method(vm, vm.number_proto, "toLocaleString", &nat_num_tolocalestring);
    def_method(vm, vm.number_proto, "valueOf", &nat_num_valueof);

    JsNative* boolean_ctor = def_global_fn(vm, "Boolean", &nat_boolean_ctor);
    props_set_desc(&boolean_ctor.props, vm.atom_prototype, value_cell(&vm.boolean_proto.head), 0);
    def_method(vm, vm.boolean_proto, "valueOf", &nat_bool_valueof);
    def_method(vm, vm.boolean_proto, "toString", &nat_bool_tostring);

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

    // Function constructor + Function.prototype
    JsNative* function_ctor = def_global_fn(vm, "Function", &nat_function_ctor);
    props_set_desc(&function_ctor.props, vm.atom_prototype, value_cell(&vm.function_proto.head), 0);
    link_ctor(vm, vm.function_proto, function_ctor);
    def_method(vm, vm.function_proto, "call", &nat_fn_call);
    def_method(vm, vm.function_proto, "apply", &nat_fn_apply);
    def_method(vm, vm.function_proto, "bind", &nat_fn_bind);

    // Errors
    JsNative* err_ctor = def_global_fn(vm, "Error", &nat_error_ctor);
    props_set_desc(&err_ctor.props, vm.atom_prototype, value_cell(&vm.error_protos[ERR_ERROR].head), 0);
    JsNative* te_ctor = def_global_fn(vm, "TypeError", &nat_typeerror_ctor);
    props_set_desc(&te_ctor.props, vm.atom_prototype, value_cell(&vm.error_protos[ERR_TYPE].head), 0);
    JsNative* re_ctor = def_global_fn(vm, "RangeError", &nat_rangeerror_ctor);
    props_set_desc(&re_ctor.props, vm.atom_prototype, value_cell(&vm.error_protos[ERR_RANGE].head), 0);
    JsNative* fe_ctor = def_global_fn(vm, "ReferenceError", &nat_referror_ctor);
    props_set_desc(&fe_ctor.props, vm.atom_prototype, value_cell(&vm.error_protos[ERR_REF].head), 0);
    JsNative* se_ctor = def_global_fn(vm, "SyntaxError", &nat_syntaxerror_ctor);
    props_set_desc(&se_ctor.props, vm.atom_prototype, value_cell(&vm.error_protos[ERR_SYNTAX].head), 0);
    JsNative* ee_ctor = def_global_fn(vm, "EvalError", &nat_evalerror_ctor);
    props_set_desc(&ee_ctor.props, vm.atom_prototype, value_cell(&vm.error_protos[ERR_EVAL].head), 0);
    JsNative* ue_ctor = def_global_fn(vm, "URIError", &nat_urierror_ctor);
    props_set_desc(&ue_ctor.props, vm.atom_prototype, value_cell(&vm.error_protos[ERR_URI].head), 0);
    for i32 i = 0; i < ERR_KIND_COUNT; i++ {
        JsObject* ep = vm.error_protos[i];
        Value nm = new_str(vm, vm_error_kind_name(i));
        js_set_prop(ep, vm.atom_name, nm);
        Value em = new_str(vm, "");
        js_set_prop(ep, vm.atom_message, em);
        def_method(vm, ep, "toString", &nat_error_tostring);
    }

    // the `arguments` object builder (called from the VM's call sites)
    vm_set_arguments_builder(vm, &build_arguments_object);

    install_proxy_reflect(vm);

    // globals
    ignore def_global_fn(vm, "structuredClone", &nat_structured_clone);
    ignore def_global_fn(vm, "encodeURIComponent", &nat_encode_uri_comp);
    ignore def_global_fn(vm, "encodeURI", &nat_encode_uri);
    ignore def_global_fn(vm, "escape", &nat_escape);
    ignore def_global_fn(vm, "unescape", &nat_unescape);
    ignore def_global_fn(vm, "decodeURIComponent", &nat_decode_uri_comp);
    ignore def_global_fn(vm, "decodeURI", &nat_decode_uri);
    ignore def_global_fn(vm, "parseInt", &nat_parseint);
    ignore def_global_fn(vm, "parseFloat", &nat_parsefloat);
    ignore def_global_fn(vm, "isNaN", &nat_global_isnan);
    ignore def_global_fn(vm, "isFinite", &nat_global_isfinite);

    // Symbol
    JsNative* symbol_ctor = def_global_fn(vm, "Symbol", &nat_symbol_ctor);
    props_set(&symbol_ctor.props, bi_atom(vm, "iterator"), vm.sym_iterator);
    props_set(&symbol_ctor.props, bi_atom(vm, "toPrimitive"), vm.sym_to_primitive);
    def_static(vm, symbol_ctor, "for", &nat_symbol_for);
    def_static(vm, symbol_ctor, "keyFor", &nat_symbol_key_for);
    vm.symbol_proto = js_new_object(&vm.heap, vm.object_proto);
    props_set_desc(&symbol_ctor.props, vm.atom_prototype, value_cell(&vm.symbol_proto.head), 0);
    def_method(vm, vm.symbol_proto, "toString", &nat_symbol_tostring);
    def_method(vm, vm.symbol_proto, "valueOf", &nat_symbol_valueof);
    def_accessor(vm, vm.symbol_proto, "description", &nat_symbol_description);
    link_ctor(vm, vm.symbol_proto, symbol_ctor);

    // BigInt
    JsNative* bigint_ctor = def_global_fn(vm, "BigInt", &nat_bigint_ctor);
    vm.bigint_proto = js_new_object(&vm.heap, vm.object_proto);
    props_set_desc(&bigint_ctor.props, vm.atom_prototype, value_cell(&vm.bigint_proto.head), 0);
    def_method(vm, vm.bigint_proto, "toString", &nat_bigint_tostring);
    def_method(vm, vm.bigint_proto, "valueOf", &nat_bigint_valueof);
    def_method(vm, vm.bigint_proto, "toLocaleString", &nat_bigint_tostring);
    link_ctor(vm, vm.bigint_proto, bigint_ctor);

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
    props_set_desc(&promise_ctor.props, vm.atom_prototype, value_cell(&vm.promise_proto.head), 0);
    def_static(vm, promise_ctor, "resolve", &nat_promise_resolve);
    def_static(vm, promise_ctor, "reject", &nat_promise_reject);
    def_static(vm, promise_ctor, "all", &nat_promise_all);
    def_static(vm, promise_ctor, "allSettled", &nat_promise_allsettled);
    def_static(vm, promise_ctor, "any", &nat_promise_any);
    def_static(vm, promise_ctor, "race", &nat_promise_race);
    def_method(vm, vm.promise_proto, "then", &nat_promise_then);
    def_method(vm, vm.promise_proto, "catch", &nat_promise_catch);
    def_method(vm, vm.promise_proto, "finally", &nat_promise_finally);

    // Map
    vm.map_proto = js_new_object(&vm.heap, vm.object_proto);
    JsNative* map_ctor = def_global_fn(vm, "Map", &nat_map_ctor);
    props_set_desc(&map_ctor.props, vm.atom_prototype, value_cell(&vm.map_proto.head), 0);
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
    props_set_desc(&set_ctor.props, vm.atom_prototype, value_cell(&vm.set_proto.head), 0);
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

    // WeakMap / WeakSet (keys held weakly; get/has/delete reuse Map's)
    vm.weakmap_proto = js_new_object(&vm.heap, vm.object_proto);
    JsNative* weakmap_ctor = def_global_fn(vm, "WeakMap", &nat_weakmap_ctor);
    props_set_desc(&weakmap_ctor.props, vm.atom_prototype, value_cell(&vm.weakmap_proto.head), 0);
    def_method(vm, vm.weakmap_proto, "set", &nat_weakmap_set);
    def_method(vm, vm.weakmap_proto, "get", &nat_map_get);
    def_method(vm, vm.weakmap_proto, "has", &nat_map_has);
    def_method(vm, vm.weakmap_proto, "delete", &nat_map_delete);
    link_ctor(vm, vm.weakmap_proto, weakmap_ctor);

    vm.weakset_proto = js_new_object(&vm.heap, vm.object_proto);
    JsNative* weakset_ctor = def_global_fn(vm, "WeakSet", &nat_weakset_ctor);
    props_set_desc(&weakset_ctor.props, vm.atom_prototype, value_cell(&vm.weakset_proto.head), 0);
    def_method(vm, vm.weakset_proto, "add", &nat_weakset_add);
    def_method(vm, vm.weakset_proto, "has", &nat_map_has);
    def_method(vm, vm.weakset_proto, "delete", &nat_map_delete);
    link_ctor(vm, vm.weakset_proto, weakset_ctor);

    // Date
    vm.date_proto = js_new_object(&vm.heap, vm.object_proto);
    JsNative* date_ctor = def_global_fn(vm, "Date", &nat_date_ctor);
    props_set_desc(&date_ctor.props, vm.atom_prototype, value_cell(&vm.date_proto.head), 0);
    def_static(vm, date_ctor, "now", &nat_date_now);
    def_static(vm, date_ctor, "UTC", &nat_date_utc);
    def_static(vm, date_ctor, "parse", &nat_date_parse);
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
    def_method(vm, vm.date_proto, "toString", &nat_date_tostring);
    def_method(vm, vm.date_proto, "toDateString", &nat_date_todatestring);
    def_method(vm, vm.date_proto, "toTimeString", &nat_date_totimestring);
    def_method(vm, vm.date_proto, "toUTCString", &nat_date_toutcstring);
    def_method(vm, vm.date_proto, "toGMTString", &nat_date_toutcstring);
    def_method(vm, vm.date_proto, "toLocaleDateString", &nat_date_tolocaledate);
    def_method(vm, vm.date_proto, "toLocaleTimeString", &nat_date_tolocaletime);
    def_method(vm, vm.date_proto, "toLocaleString", &nat_date_tolocalestring);
    JsNative* date_tp = js_new_native(&vm.heap, &nat_date_toprimitive, "[Symbol.toPrimitive]");
    props_set_desc(&vm.date_proto.props, vm_sym_to_primitive_id(vm),
        value_cell(&date_tp.head), METHOD_ATTRS);

    // RegExp
    vm.regexp_proto = js_new_object(&vm.heap, vm.object_proto);
    JsNative* regexp_ctor = def_global_fn(vm, "RegExp", &nat_regexp_ctor);
    props_set_desc(&regexp_ctor.props, vm.atom_prototype, value_cell(&vm.regexp_proto.head), 0);
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

    // Buffer, text codecs, process: installed before the globalThis
    // snapshot so they are mirrored onto it.
    typedarray_install(vm);
    buffer_install(vm);
    net_install(vm);
    textcodec_install(vm);
    usp_install(vm);
    url_install(vm);
    process_install(vm);

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
    // Node exposes the same global object as `global` too (=== globalThis).
    props_set_desc(&gt.props, bi_atom(vm, "global"), gtv, METHOD_ATTRS);
    vm_set_global(vm, "global", gtv);
}

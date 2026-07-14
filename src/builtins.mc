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
import vm;
import math;

private VM* as_vm(void* p) {
    return cast(VM*, p);
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

// Pushes own enumerable keys of o into arr (rooted by the caller).
private void collect_keys(VM* vm, JsObject* o, JsObject* arr) {
    i32 n = arr.elen;
    if (o.obj_flags & OBJF_ARRAY) != 0 {
        for i32 i = 0; i < o.elen; i++ {
            string s = format("{}", i);
            Value ks = new_str(vm, s);
            free(s);
            js_array_set(arr, n, ks);
            n++;
        }
    }
    for i32 i = 0; i < o.props.len; i++ {
        str nm = atom_name(&vm.atoms, (o.props.items + i).key);
        Value ks = new_str(vm, nm);
        js_array_set(arr, n, ks);
        n++;
    }
}

private Value nat_object_keys(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    JsObject* arr = js_new_array(&vm.heap, vm.array_proto);
    i32 rm = gc_root_mark(&vm.heap);
    gc_root(&vm.heap, value_cell(&arr.head));
    Value ov = arg_at(args, argc, 0);
    if value_is_object(ov) {
        collect_keys(vm, value_as_object(ov), arr);
    }
    gc_root_reset(&vm.heap, rm);
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
                js_array_set(arr, n, js_array_get(o, i));
                n++;
            }
        }
        for i32 i = 0; i < o.props.len; i++ {
            js_array_set(arr, n, (o.props.items + i).val);
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
            JsObject* pair = js_new_array(&vm.heap, vm.array_proto);
            js_array_set(arr, n, value_cell(&pair.head));
            Value ks = new_str(vm, atom_name(&vm.atoms, (o.props.items + i).key));
            js_array_set(pair, 0, ks);
            js_array_set(pair, 1, (o.props.items + i).val);
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
            js_set_prop(t, (src.props.items + i).key, (src.props.items + i).val);
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
    Value ov = arg_at(args, argc, 0);
    if value_is_object(ov) {
        JsObject* p = value_as_object(ov).proto;
        if p != null { return value_cell(&p.head); }
    }
    return value_null();
}

private Value nat_has_own(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    if !value_is_object(thisv) { return value_bool(false); }
    JsObject* o = value_as_object(thisv);
    Value kv = arg_at(args, argc, 0);
    if (o.obj_flags & OBJF_ARRAY) != 0 && value_is_int(kv) {
        i32 i = value_as_int(kv);
        return value_bool(i >= 0 && i < o.elen);
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
        str s = sview(src);
        for i32 i = 0; i < s.len; i++ {
            str one;
            one.data = s.data + i;
            one.len = 1;
            Value cs = new_str(vm, one);
            js_array_set(arr, i, cs);
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
        js_array_set(r, n, js_array_get(a, i));
        n++;
    }
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
        js_array_set(r, n, js_array_get(a, i));
        n++;
    }
    for i32 s = 0; s < argc; s++ {
        Value v = *(args + s);
        if value_is_array(v) {
            JsObject* o = value_as_object(v);
            for i32 i = 0; i < o.elen; i++ {
                js_array_set(r, n, js_array_get(o, i));
                n++;
            }
        } else {
            js_array_set(r, n, v);
            n++;
        }
    }
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
    i32 n = 0;
    for i32 i = 0; i < a.elen; i++ {
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
        if a.elen == 0 {
            vm_throw_error(vm, ERR_TYPE, "reduce of empty array with no initial value");
            return value_undefined();
        }
        acc = js_array_get(a, 0);
        i = 1;
    }
    i32 rm = gc_root_mark(&vm.heap);
    while i < a.elen {
        gc_root(&vm.heap, acc);
        Value[4] cargs = { acc, js_array_get(a, i), value_int(i), thisv };
        acc = vm_call_value(vm, fun, value_undefined(), &cargs[0], 4);
        gc_root_reset(&vm.heap, rm);
        if vm.has_pending { return value_undefined(); }
        i++;
    }
    return acc;
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

// --- String -------------------------------------------------------------------

private Value nat_string_ctor(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    if argc == 0 { return new_str(vm, ""); }
    return js_to_string_value(vm, *(args));
}

private Value nat_string_fromcharcode(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    u8* buf = alloc<u8>(argc * 4 + 1);
    i32 n = 0;
    for i32 i = 0; i < argc; i++ {
        f64 d = js_to_number(*(args + i));
        u32 cp = 0;
        if d == d && d >= 0.0 && d <= 1114111.0 { cp = cast(u32, cast(i64, d)); }
        n += bi_utf8_encode(buf + n, cp);
    }
    str s;
    s.data = buf;
    s.len = n;
    Value r = new_str(vm, s);
    free(buf);
    return r;
}

private Value nat_str_charat(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    i32 rm = gc_root_mark(&vm.heap);
    Value sv2 = js_to_string_value(vm, thisv);
    gc_root(&vm.heap, sv2);
    str s = sview(sv2);
    i32 i = to_int_arg(arg_at(args, argc, 0));
    Value r;
    if i >= 0 && i < s.len {
        str one;
        one.data = s.data + i;
        one.len = 1;
        r = new_str(vm, one);
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
    gc_root_reset(&vm.heap, rm);
    if i >= 0 && i < s.len {
        i32 b = *(s.data + i);
        return value_int(b);
    }
    return value_number(0.0 / 0.0);
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
    i32 start_at = argc > 1 ? to_int_arg(*(args + 1)) : 0;
    i32 r = str_find_from(sview(sv2), sview(nv), start_at);
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
    str hay = sview(sv2);
    str needle = sview(nv);
    i32 best = -1;
    i32 i = 0;
    while true {
        i32 f = str_find_from(hay, needle, i);
        if f < 0 { break; }
        best = f;
        i = f + 1;
    }
    gc_root_reset(&vm.heap, rm);
    return value_int(best);
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
    str s = sview(sv2);
    i32 start = rel_index(argc > 0 ? to_int_arg(*(args)) : 0, s.len);
    i32 end = s.len;
    if argc > 1 && !value_is_undefined(*(args + 1)) {
        end = rel_index(to_int_arg(*(args + 1)), s.len);
    }
    if end < start { end = start; }
    str sub;
    sub.data = s.data + start;
    sub.len = end - start;
    Value r = new_str(vm, sub);
    gc_root_reset(&vm.heap, rm);
    return r;
}

private Value nat_str_substring(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    i32 rm = gc_root_mark(&vm.heap);
    Value sv2 = js_to_string_value(vm, thisv);
    gc_root(&vm.heap, sv2);
    str s = sview(sv2);
    i32 a = argc > 0 ? to_int_arg(*(args)) : 0;
    i32 b = s.len;
    if argc > 1 && !value_is_undefined(*(args + 1)) {
        b = to_int_arg(*(args + 1));
    }
    if a < 0 { a = 0; }
    if b < 0 { b = 0; }
    if a > s.len { a = s.len; }
    if b > s.len { b = s.len; }
    if a > b {
        i32 t = a;
        a = b;
        b = t;
    }
    str sub;
    sub.data = s.data + a;
    sub.len = b - a;
    Value r = new_str(vm, sub);
    gc_root_reset(&vm.heap, rm);
    return r;
}

private Value str_case_map(VM* vm, Value thisv, bool upper) {
    i32 rm = gc_root_mark(&vm.heap);
    Value sv2 = js_to_string_value(vm, thisv);
    gc_root(&vm.heap, sv2);
    str s = sview(sv2);
    u8* buf = alloc<u8>(s.len + 1);
    for i32 i = 0; i < s.len; i++ {
        u8 c = *(s.data + i);
        if upper && c >= 'a' && c <= 'z' { c = cast(u8, c - 32); }
        if !upper && c >= 'A' && c <= 'Z' { c = cast(u8, c + 32); }
        *(buf + i) = c;
    }
    str out;
    out.data = buf;
    out.len = s.len;
    Value r = new_str(vm, out);
    free(buf);
    gc_root_reset(&vm.heap, rm);
    return r;
}

private Value nat_str_toupper(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    return str_case_map(as_vm(vmp), thisv, true);
}

private Value nat_str_tolower(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    return str_case_map(as_vm(vmp), thisv, false);
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
    i32 n = 0;
    if sep.len == 0 {
        for i32 i = 0; i < s.len; i++ {
            str one;
            one.data = s.data + i;
            one.len = 1;
            js_array_set(arr, n, new_str(vm, one));
            n++;
        }
    } else {
        i32 at = 0;
        while true {
            i32 f = str_find_from(s, sep, at);
            if f < 0 { break; }
            str part;
            part.data = s.data + at;
            part.len = f - at;
            js_array_set(arr, n, new_str(vm, part));
            n++;
            at = f + sep.len;
        }
        str tail;
        tail.data = s.data + at;
        tail.len = s.len - at;
        js_array_set(arr, n, new_str(vm, tail));
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
    i32 target = to_int_arg(arg_at(args, argc, 0));
    str pad = " ";
    if argc > 1 && !value_is_undefined(*(args + 1)) {
        Value pv = js_to_string_value(vm, *(args + 1));
        gc_root(&vm.heap, pv);
        pad = sview(pv);
    }
    if target <= s.len || pad.len == 0 {
        gc_root_reset(&vm.heap, rm);
        return sv2;
    }
    str_buf sb;
    str_buf_init(&sb);
    if !at_start { str_buf_add(&sb, s); }
    i32 need = target - s.len;
    while need > 0 {
        str piece = pad;
        if piece.len > need { piece.len = need; }
        str_buf_add(&sb, piece);
        need -= piece.len;
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
    // JS rounds half toward +inf
    return math1(floor(js_to_number(arg_at(args, argc, 0)) + 0.5));
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

private void json_indent_into(str_buf* sb, i32 indent, i32 depth) {
    if indent <= 0 { return; }
    str_buf_add(sb, "\n");
    for i32 i = 0; i < indent * depth; i++ {
        str_buf_add(sb, " ");
    }
}

// Returns false when the value is unrepresentable (undefined/function).
private bool json_write(VM* vm, str_buf* sb, Value v, Vec<u64>* seen, i32 indent, i32 depth) {
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
            json_indent_into(sb, indent, depth + 1);
            if !json_write(vm, sb, js_array_get(o, i), seen, indent, depth + 1) {
                if vm.has_pending {
                    ignore vec_pop(seen);
                    return false;
                }
                str_buf_add(sb, "null");
            }
        }
        if o.elen > 0 { json_indent_into(sb, indent, depth); }
        str_buf_add(sb, "]");
    } else {
        str_buf_add(sb, "{");
        bool first = true;
        for i32 i = 0; i < o.props.len; i++ {
            Prop* p = o.props.items + i;
            if value_is_undefined(p.val) || value_is_callable(p.val) { continue; }
            str_buf sub;
            str_buf_init(&sub);
            if !json_write(vm, &sub, p.val, seen, indent, depth + 1) {
                str_buf_free(&sub);
                if vm.has_pending {
                    ignore vec_pop(seen);
                    return false;
                }
                continue;
            }
            if !first { str_buf_add(sb, ","); }
            json_indent_into(sb, indent, depth + 1);
            json_escape_into(sb, atom_name(&vm.atoms, p.key));
            str_buf_add(sb, indent > 0 ? ": " : ":");
            str_buf_add(sb, str_buf_to_str(&sub));
            str_buf_free(&sub);
            first = false;
        }
        if !first { json_indent_into(sb, indent, depth); }
        str_buf_add(sb, "}");
    }
    ignore vec_pop(seen);
    return true;
}

private Value nat_json_stringify(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = as_vm(vmp);
    Value v = arg_at(args, argc, 0);
    i32 indent = 0;
    if argc > 2 && value_is_number(*(args + 2)) {
        indent = to_int_arg(*(args + 2));
        if indent < 0 { indent = 0; }
        if indent > 10 { indent = 10; }
    }
    str_buf sb;
    str_buf_init(&sb);
    Vec<u64> seen = vec_new<u64>(8);
    bool ok = json_write(vm, &sb, v, &seen, indent, 0);
    vec_free(&seen);
    if !ok {
        str_buf_free(&sb);
        return value_undefined();
    }
    Value r = new_str(vm, str_buf_to_str(&sb));
    str_buf_free(&sb);
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
        Value s = js_to_string_value(vm, *(args + i));
        gc_root(&vm.heap, s);
        if to_err { eprint("{}", sview(s)); } else { print("{}", sview(s)); }
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

// --- install -------------------------------------------------------------------------------------

private void def_method(VM* vm, JsObject* obj, str name, NativeFn f) {
    JsNative* n = js_new_native(&vm.heap, f, name);
    js_set_prop(obj, bi_atom(vm, name), value_cell(&n.head));
}

private JsNative* def_global_fn(VM* vm, str name, NativeFn f) {
    JsNative* n = js_new_native(&vm.heap, f, name);
    vm_set_global(vm, name, value_cell(&n.head));
    return n;
}

private void def_static(VM* vm, JsNative* ctor, str name, NativeFn f) {
    JsNative* m = js_new_native(&vm.heap, f, name);
    props_set(&ctor.props, bi_atom(vm, name), value_cell(&m.head));
}

private void def_value(VM* vm, JsObject* obj, str name, Value v) {
    js_set_prop(obj, bi_atom(vm, name), v);
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
    def_method(vm, vm.array_proto, "some", &nat_arr_some);
    def_method(vm, vm.array_proto, "every", &nat_arr_every);
    def_method(vm, vm.array_proto, "find", &nat_arr_find);
    def_method(vm, vm.array_proto, "findIndex", &nat_arr_findindex);
    def_method(vm, vm.array_proto, "reverse", &nat_arr_reverse);
    def_method(vm, vm.array_proto, "sort", &nat_arr_sort);
    def_method(vm, vm.array_proto, "fill", &nat_arr_fill);

    // String
    JsNative* string_ctor = def_global_fn(vm, "String", &nat_string_ctor);
    props_set(&string_ctor.props, vm.atom_prototype, value_cell(&vm.string_proto.head));
    def_static(vm, string_ctor, "fromCharCode", &nat_string_fromcharcode);
    def_method(vm, vm.string_proto, "charAt", &nat_str_charat);
    def_method(vm, vm.string_proto, "charCodeAt", &nat_str_charcodeat);
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
    def_method(vm, vm.string_proto, "replace", &nat_str_replace);
    def_method(vm, vm.string_proto, "replaceAll", &nat_str_replaceall);
    def_method(vm, vm.string_proto, "toString", &nat_str_tostring);

    // Number / Boolean
    JsNative* number_ctor = def_global_fn(vm, "Number", &nat_number_ctor);
    props_set(&number_ctor.props, vm.atom_prototype, value_cell(&vm.number_proto.head));
    def_static(vm, number_ctor, "isInteger", &nat_num_isinteger);
    def_static(vm, number_ctor, "isFinite", &nat_num_isfinite);
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
    def_method(vm, math_obj, "min", &nat_math_min);
    def_method(vm, math_obj, "max", &nat_math_max);
    def_method(vm, math_obj, "random", &nat_math_random);

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
    ignore def_global_fn(vm, "parseInt", &nat_parseint);
    ignore def_global_fn(vm, "parseFloat", &nat_parsefloat);
    ignore def_global_fn(vm, "isNaN", &nat_global_isnan);
    ignore def_global_fn(vm, "isFinite", &nat_global_isfinite);

    // console.warn / console.info
    Value* cv = intmap_get<Value>(&vm.globals, bi_atom(vm, "console"));
    if cv != null && value_is_object(*cv) {
        JsObject* con = value_as_object(*cv);
        def_method(vm, con, "warn", &nat_console_warn);
        def_method(vm, con, "info", &nat_console_info);
    }
}

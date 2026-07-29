// demo.mc — a tsmc plugin: native functions written in minc.
//
//   const demo = require('./demo.mc');
//
// tsmc compiles this file and loads it when the require runs. Nothing here
// links against the interpreter: the api table arrives at registration and
// is the only way in or out.

import "../../src/tsmc_plugin_abi.mc";

// The interpreter keeps its api table alive for the process, so holding the
// pointer here is safe. The natives below need it and are called with only
// the vm handle.
private TsmcApi* api = null;

private Value nat_hello(void* vm, Value callee, Value thisv, Value* args, i32 argc) {
    return api.new_string(vm, "hello from a minc plugin");
}

// Arguments arrive as JS values, so coerce rather than assume: sum('4', 5)
// is 9, the same as it would be in JS.
private Value nat_sum(void* vm, Value callee, Value thisv, Value* args, i32 argc) {
    f64 a = api.to_number(vm, api.arg(args, argc, 0));
    f64 b = api.to_number(vm, api.arg(args, argc, 1));
    return api.new_number(a + b);
}

// Builds { label, x, y }.
//
// The object is pushed on the root stack before anything else is allocated.
// Each new_string / new_number below can trigger a collection, and this
// local is not somewhere the collector looks -- without the push, the object
// can be freed halfway through being filled in.
private Value nat_point(void* vm, Value callee, Value thisv, Value* args, i32 argc) {
    if argc < 2 {
        api.throw_type_error(vm, "point(x, y) wants two arguments");
        return api.new_undefined();
    }
    f64 x = api.to_number(vm, api.arg(args, argc, 0));
    f64 y = api.to_number(vm, api.arg(args, argc, 1));

    Value o = api.new_object(vm);
    api.push_root(vm, o);
    api.set_prop(vm, o, "label", api.new_string(vm, "point"));
    api.set_prop(vm, o, "x", api.new_number(x));
    api.set_prop(vm, o, "y", api.new_number(y));
    api.pop_root(vm);
    return o;
}

// --- the two symbols tsmc looks up. Both must be public. ---

u32 tsmc_plugin_abi_version() { return TSMC_PLUGIN_ABI; }

void tsmc_plugin_register(TsmcApi* a, void* reg) {
    api = a;
    a.export_fn(reg, "hello", &nat_hello);
    a.export_fn(reg, "sum", &nat_sum);
    a.export_fn(reg, "point", &nat_point);
}

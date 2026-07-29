// tsmc_plugin_abi.mc — the interpreter <-> plugin contract.
//
// A plugin is minc source that tsmc compiles and loads at require() time.
// It is built as its own program, so it shares no symbols with the
// interpreter: every service arrives through the TsmcApi table it is handed
// at registration. Both sides import this file, and TSMC_PLUGIN_ABI is
// checked before any of a plugin's exports are called, so a plugin built
// against an older table is refused rather than run.
//
// Rules at the seam:
//
// - Handles (vm, reg) are opaque. A plugin passes them back and never
//   dereferences them.
//
// - Values cross by value. One NaN-boxed word, so there is no layout to
//   agree on beyond its size.
//
// - A Value the plugin still needs across a call that can allocate must be
//   rooted with push_root/pop_root. The collector walks an explicit root
//   stack rather than the machine stack, so a Value sitting only in a
//   plugin local is invisible to it and its object can be collected while
//   the plugin is still holding it. new_string, new_object and set_prop all
//   allocate.
//
// - export_fn is valid only during tsmc_plugin_register.

const u32 TSMC_PLUGIN_ABI = 1;

// Same one-word layout as the interpreter's Value. Declared here so a
// plugin needs nothing from src/ but this file.
struct Value { u64 bits; }

// A plugin's native function. The first parameter is the vm handle; the
// rest are the JS call: callee, `this`, the argument array and its length.
type TsmcNative = fn(void*, Value, Value, Value*, i32): Value;

struct TsmcApi {
    u32 abi_version;

    // Registration. Names a function as an export of the module being built.
    fn(void*, str, TsmcNative): void   export_fn;      // (reg, name, fn)

    // Making values.
    fn(void*, str): Value              new_string;     // (vm, text)
    fn(f64): Value                     new_number;
    fn(): Value                        new_undefined;
    fn(void*): Value                   new_object;     // (vm)

    // Reading arguments. `arg` yields undefined past the end.
    fn(Value*, i32, i32): Value        arg;            // (args, argc, index)
    fn(void*, Value): f64              to_number;      // (vm, v) — ToNumber

    // Building objects.
    fn(void*, Value, str, Value): void set_prop;       // (vm, obj, name, v)

    // The root stack. Every push needs its pop.
    fn(void*, Value): void             push_root;      // (vm, v)
    fn(void*): void                    pop_root;       // (vm)

    // Throwing. The native must return straight after; the interpreter
    // unwinds when it regains control.
    fn(void*, str): void               throw_type_error;   // (vm, message)
}

// The two symbols tsmc resolves in a freshly compiled plugin. Both must be
// public in the plugin source, or they are not in its export table.
type TsmcPluginAbiFn = fn(): u32;                     // tsmc_plugin_abi_version
type TsmcPluginRegFn = fn(TsmcApi*, void*): void;     // tsmc_plugin_register

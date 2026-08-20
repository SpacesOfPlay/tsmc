# plugin — native functions written in minc

A plugin is minc source that tsmc compiles and loads when a script requires
it. `require('./demo.mc')` returns a module whose functions are native code.

```
minc build.mc -o build/build.exe   # once
build/build.exe plugins            # -> build/tsmc-plugins[.exe]
./build/tsmc-plugins.exe examples/plugin/demo.js
```

The default `tsmc` has no plugin support; requiring a `.mc` file from it
throws `TypeError: this build has no plugin support`. Plugins are a separate
binary because the embeddable compiler is bound at load time, so that binary
needs the library beside it (the build target copies it into `build/`).

## The seam

`src/tsmc_plugin_abi.mc` is the whole contract, imported by both sides. A
plugin is built as its own program and shares no symbols with the
interpreter, so everything arrives through the `TsmcApi` table it is handed
at registration: making values, reading arguments, setting properties,
throwing, and the root stack.

Two public functions are looked up by name:

```c
u32  tsmc_plugin_abi_version()               // must equal TSMC_PLUGIN_ABI
void tsmc_plugin_register(TsmcApi*, void*)   // names the exports
```

`TSMC_PLUGIN_ABI` is checked before anything else in the plugin is called, so
a plugin built against an older table is refused rather than run. A compile
error comes back as a catchable JS exception carrying the compiler's
diagnostics.

## Rooting

A Value the plugin holds across a call that can allocate has to be pushed on
the root stack. The collector walks that stack, not the machine stack, so a
Value sitting in a plugin local is not something it can see. `nat_point` in
`demo.mc` shows the shape: the object is pushed before the strings and
numbers that go into it are allocated.

Getting this wrong is quiet. `gcstress.js` builds 200 objects under
`--gc-stress` while churning through JS allocations, which is what it takes
to make the bug visible — with the push removed, the object is collected and
its cell comes back as something else entirely, so a `{label, x, y}` read as
`[1,2,3]`. Without the churn the freed cell still reads correctly and the
same run passes, so `--gc-stress` alone is not the test; `--gc-stress` plus
allocation after the unrooted window is.

## Limits

- **Load only.** A loaded plugin is never released. Its natives' code
  pointers travel into the GC heap and from there into whatever the script
  does with the functions, so unloading would leave those cells pointing at
  unmapped pages. Reloading on edit needs an indirection the natives can be
  re-pointed through, and a safe point at which no plugin frame is live.
- **`require` only.** The ESM resolver has no plugin branch, so `import` of a
  `.mc` file tries to parse it as JavaScript.
- **Not in the test suite.** It needs a plugin-enabled build and the
  compiler library, so `minc test` does not cover it.

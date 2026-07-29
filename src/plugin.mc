// plugin.mc — compiling and loading a minc plugin at runtime.
//
// Built only when TSMC_PLUGINS is defined, so a default tsmc has no
// compiler dependency and this file collapses to the stubs at the bottom.
// The embeddable compiler is bound at load time here, which means the
// binary needs it present to start; making plugins optional in a shipped
// build means resolving these same entry points by name instead.
//
// This layer is deliberately ignorant of JS: it compiles a file, hands back
// an opaque module and resolves symbols in it. Everything about Values and
// registration lives in builtins.mc, which owns the api table.

import str;

// The compiler's own ABI. Checked before the first compile: a library that
// does not match was built for a different table than this file describes.
const i32 TSMC_MINC_ABI = 1;

when defined(TSMC_PLUGINS) && os(windows) {
    extern "libminc.dll" {
        void* minc_create();
        void* minc_compile_file(void* ctx, u8* path);
        u8*   minc_errors(void* ctx);
        void* minc_sym(void* module, u8* name);
        void  minc_module_free(void* module);
        i32   minc_abi_version();
    }
}

when defined(TSMC_PLUGINS) && os(macos) {
    extern "libminc.dylib" {
        void* minc_create();
        void* minc_compile_file(void* ctx, u8* path);
        u8*   minc_errors(void* ctx);
        void* minc_sym(void* module, u8* name);
        void  minc_module_free(void* module);
        i32   minc_abi_version();
    }
}

when defined(TSMC_PLUGINS) && os(linux) {
    extern "libminc.so" {
        void* minc_create();
        void* minc_compile_file(void* ctx, u8* path);
        u8*   minc_errors(void* ctx);
        void* minc_sym(void* module, u8* name);
        void  minc_module_free(void* module);
        i32   minc_abi_version();
    }
}

when defined(TSMC_PLUGINS) {
    private void* g_plugin_ctx = null;
    private bool g_plugin_tried = false;
    private str g_plugin_error = "";

    bool plugin_support_built() { return true; }

    // Creates the compiler context on first use. A failure is remembered, so
    // a second require does not retry a compiler that is not going to work.
    bool plugin_host_ready() {
        if g_plugin_ctx != null { return true; }
        if g_plugin_tried { return false; }
        g_plugin_tried = true;
        if minc_abi_version() != TSMC_MINC_ABI {
            g_plugin_error = "the installed minc library has a different ABI than this build expects";
            return false;
        }
        g_plugin_ctx = minc_create();
        if g_plugin_ctx == null {
            g_plugin_error = "could not create a compiler context";
            return false;
        }
        return true;
    }

    // Compiles and loads `path` in-process. Null on failure, with the
    // diagnostics left in plugin_host_error().
    void* plugin_compile(str path) {
        u8* c = str_to_cstr(path);
        void* mod = minc_compile_file(g_plugin_ctx, c);
        free(c);
        if mod == null { g_plugin_error = str_from_cstr(minc_errors(g_plugin_ctx)); }
        return mod;
    }

    void* plugin_symbol(void* mod, str name) {
        u8* c = str_to_cstr(name);
        void* p = minc_sym(mod, c);
        free(c);
        return p;
    }

    void plugin_release(void* mod) { minc_module_free(mod); }

    str plugin_host_error() { return g_plugin_error; }
}
else {
    bool plugin_support_built() { return false; }
    bool plugin_host_ready() { return false; }
    void* plugin_compile(str path) { return null; }
    void* plugin_symbol(void* mod, str name) { return null; }
    void plugin_release(void* mod) { }
    str plugin_host_error() { return "this build has no plugin support (compile with -DTSMC_PLUGINS)"; }
}

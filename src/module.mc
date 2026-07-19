// module.mc — ES module loading, resolution, and evaluation.
//
// Resolve a specifier to a file, parse+lower+compile each module once
// (deduped by path), then evaluate in dependency post-order. Each
// module function receives its own namespace object plus its
// dependencies' namespaces. See doc/PLAN_M10_modules.md.

import vec;
import str;
import file;
import diag;
import bump;
import ast;
import parser;
import lower;
import compiler;
import value;
import gc;
import object;
import atom;
import vm;
import builtins;
import node_stream;
import node_assert;

// Canonical file identity for module dedup: resolves symlinks and
// on-disk case, so two spellings of the same file load as one module.
when os(windows) {
    extern "kernel32.dll" {
        i64 CreateFileA(u8* name, i32 access, i32 share, void* sec,
            i32 disposition, i32 flags, i64 template_file);
        i32 GetFinalPathNameByHandleA(i64 handle, u8* buf, i32 cap, i32 flags);
        i32 CloseHandle(i64 handle);
    }
    // Final path by handle: symlinks and junctions resolved, on-disk
    // case. 0x02000000 is FILE_FLAG_BACKUP_SEMANTICS (allows opening
    // directories); share mode 7 is read|write|delete.
    private bool canon_into(u8* cpath, u8* buf, i32 cap) {
        i64 h = CreateFileA(cpath, 0, 7, null, 3, 0x02000000, cast(i64, 0));
        if h == cast(i64, 0) - 1 { return false; }
        i32 n = GetFinalPathNameByHandleA(h, buf, cap, 0);
        CloseHandle(h);
        return n > 0 && n < cap;
    }
    extern "kernel32.dll" u32 GetFileAttributesA(u8* path);
    private bool path_is_dir(str p) {
        u8* c = str_to_cstr(p);
        u32 a = GetFileAttributesA(c);
        free(c);
        if a == 0xFFFFFFFF { return false; }
        return (a & 0x10) != 0;   // FILE_ATTRIBUTE_DIRECTORY
    }
}
when os(linux) {
    extern "libc.so.6" u8* sys_realpath(u8* path, u8* resolved) from "realpath";
}
when os(android) {
    extern "libc.so" u8* sys_realpath(u8* path, u8* resolved) from "realpath";
}
when os(macos) || os(ios) {
    extern "libSystem.B.dylib" u8* sys_realpath(u8* path, u8* resolved) from "realpath";
}
when os(macos) || os(ios) {
    extern "libSystem.B.dylib" void* opendir(u8* path);
    extern "libSystem.B.dylib" i32 closedir(void* dp);
}
when os(linux) || os(android) {
    extern "libc.so.6" void* opendir(u8* path);
    extern "libc.so.6" i32 closedir(void* dp);
}
when !os(windows) {
    // opendir succeeds only for directories — a layout-free type check.
    private bool path_is_dir(str p) {
        u8* c = str_to_cstr(p);
        void* d = opendir(c);
        free(c);
        if d == null { return false; }
        ignore closedir(d);
        return true;
    }
    // resolved buffer must hold PATH_MAX; callers pass 4096.
    private bool canon_into(u8* cpath, u8* buf, i32 cap) {
        return sys_realpath(cpath, buf) != null;
    }
}

const i32 MOD_NEW = 0;
const i32 MOD_LOADED = 1;
const i32 MOD_EVALUATING = 2;
const i32 MOD_DONE = 3;

struct Module {
    str path;             // resolved, owned
    str canon;            // canonical identity key for dedup, owned
    u8* src_data;         // owned file bytes
    i32 src_len;
    Bump arena;
    FnTemplate* tmpl;
    Vec<i32> dep_idx;     // resolved dependency module indices, slot order
    JsObject* ns;
    i32 state;
    bool ok;
}

type ModulePtr = Module*;

struct Loader {
    VM* vm;
    Vec<ModulePtr> mods;
    DiagList diags;
    bool failed;
}

// --- path handling -----------------------------------------------------------

private str dir_of(str path) {
    i32 sep = -1;
    for i32 i = 0; i < path.len; i++ {
        u8 c = *(path.data + i);
        if c == '/' || c == '\\' { sep = i; }
    }
    str d;
    d.data = path.data;
    d.len = sep + 1;   // includes trailing separator, empty if none
    return d;
}

// Path helpers return heap strs the caller frees; {null, 0} means none.

private str raw_from(str_buf* sb) {
    str v = str_buf_to_str(sb);
    u8* d = alloc<u8>(v.len > 0 ? v.len : 1);
    if v.len > 0 { memcpy(d, v.data, v.len); }
    str r;
    r.data = d;
    r.len = v.len;
    return r;
}

// Joins base dir + relative specifier and normalizes ./ and ../ .
private str path_join(str dir, str spec) {
    str_buf sb;
    str_buf_init(&sb);
    str_buf_add(&sb, dir);
    str_buf_add(&sb, spec);
    str joined = str_buf_to_str(&sb);
    // Leading separators to restore: one for an absolute path, two for
    // a UNC root ("\\server\share").
    i32 lead = 0;
    while lead < 2 && lead < joined.len &&
        (*(joined.data + lead) == '/' || *(joined.data + lead) == '\\') { lead++; }
    Vec<str> segs = vec_new<str>(8);
    i32 i = 0;
    while i < joined.len {
        i32 start = i;
        while i < joined.len && *(joined.data + i) != '/' && *(joined.data + i) != '\\' { i++; }
        str seg;
        seg.data = joined.data + start;
        seg.len = i - start;
        if seg.len == 1 && *(seg.data) == '.' {
            // current dir: skip
        } else if seg.len == 2 && *(seg.data) == '.' && *(seg.data + 1) == '.' {
            if segs.len > 0 { segs.len = segs.len - 1; }
        } else if seg.len > 0 {
            vec_push(&segs, seg);
        }
        i++;
    }
    str_buf out;
    str_buf_init(&out);
    for i32 k = 0; k < lead; k++ { str_buf_add(&out, "/"); }
    for i32 j = 0; j < segs.len; j++ {
        if j > 0 { str_buf_add(&out, "/"); }
        str_buf_add(&out, vec_get(&segs, j));
    }
    str r = raw_from(&out);
    str_buf_free(&out);
    str_buf_free(&sb);
    vec_free(&segs);
    return r;
}

private bool file_there(str path) {
    u8* c = str_to_cstr(path);
    bool ok = file_exists(c);
    free(c);
    return ok;
}

// joined + suffix if that file exists (heap str), else {null, 0}.
private str try_candidate(str joined, str suffix) {
    str_buf sb;
    str_buf_init(&sb);
    str_buf_add(&sb, joined);
    str_buf_add(&sb, suffix);
    str cand = raw_from(&sb);
    str_buf_free(&sb);
    if file_there(cand) { return cand; }
    free(cand.data);
    str none;
    none.data = null;
    none.len = 0;
    return none;
}

// Resolves a relative specifier; returns a heap str (.data freed by
// the caller) or {null, 0} if no file matches. The empty suffix is the
// exact-path try; the rest add an inferred extension or /index.
private str resolve_specifier(str importer, str spec) {
    str dir = dir_of(importer);
    str joined = path_join(dir, spec);
    str[8] tries = { "", ".ts", ".js", ".mjs", ".mts",
        "/index.ts", "/index.js", "/index.mts" };
    str r;
    r.data = null;
    r.len = 0;
    for i32 e = 0; e < 8; e++ {
        if r.data == null { r = try_candidate(joined, tries[e]); }
    }
    free(joined.data);
    return r;
}

// Canonical identity key (heap str) for module dedup. The lexical path
// stays the one used for reads, resolution, and messages. Falls back to
// a copy of the lexical path when the file cannot be canonicalized.
private str canon_path(str path) {
    u8* cpath = str_to_cstr(path);
    u8* buf = alloc<u8>(4096);
    if canon_into(cpath, buf, 4096) {
        free(cpath);
        return str_from_cstr(buf);
    }
    free(buf);
    free(cpath);
    u8* d = alloc<u8>(path.len > 0 ? path.len : 1);
    if path.len > 0 { memcpy(d, path.data, path.len); }
    str r;
    r.data = d;
    r.len = path.len;
    return r;
}

// --- loading -----------------------------------------------------------------

private i32 find_module(Loader* ld, str canon) {
    for i32 i = 0; i < ld.mods.len; i++ {
        if str_equal(vec_get(&ld.mods, i).canon, canon) { return i; }
    }
    return -1;
}

private bool str_has_prefix(str s, str pre) {
    if s.len < pre.len { return false; }
    for i32 i = 0; i < pre.len; i++ {
        if *(s.data + i) != *(pre.data + i) { return false; }
    }
    return true;
}

// If spec names a supported built-in module ("fs"/"path", with or without
// a "node:" prefix), returns the bare name; else {null, 0}.
private str builtin_name(str spec) {
    str s = spec;
    if str_has_prefix(s, "node:") {
        s.data = s.data + 5;
        s.len = s.len - 5;
    }
    if str_equal(s, "fs") || str_equal(s, "path") || str_equal(s, "os")
        || str_equal(s, "events") || str_equal(s, "util")
        || str_equal(s, "crypto") || str_equal(s, "stream")
        || str_equal(s, "assert") { return s; }
    str none;
    none.data = null;
    none.len = 0;
    return none;
}

// Binds a synthetic, pre-evaluated module for a built-in namespace.
// Deduped by a "node:<name>" canonical key. Returns the module index,
// or -1 if the name is unknown.
private i32 load_builtin_module(Loader* ld, str name) {
    str_buf cb;
    str_buf_init(&cb);
    str_buf_add(&cb, "node:");
    str_buf_add(&cb, name);
    str canon = raw_from(&cb);
    str_buf_free(&cb);
    i32 existing = find_module(ld, canon);
    if existing >= 0 { free(canon.data); return existing; }

    JsObject* ns = builtins_node_module(ld.vm, name);
    if ns == null {
        // JS-source built-in (e.g. stream): run it, wrap exports as a namespace
        str jsrc = builtin_js_source(name);
        if jsrc.data == null { free(canon.data); return -1; }
        Value exports = run_js_builtin(ld.vm, name, jsrc);
        if !value_is_object(exports) && !value_is_function(exports) { free(canon.data); return -1; }
        ns = js_builtin_namespace(ld.vm, exports);
    }

    Module* mod = new(Module);
    u8* pc = alloc<u8>(name.len > 0 ? name.len : 1);
    if name.len > 0 { memcpy(pc, name.data, name.len); }
    mod.path.data = pc;
    mod.path.len = name.len;
    mod.canon = canon;
    mod.src_data = null;
    mod.src_len = 0;
    mod.state = MOD_DONE;
    mod.ok = true;
    vec_init<i32>(&mod.dep_idx, 1);
    bump_init(&mod.arena);
    mod.tmpl = null;
    mod.ns = ns;
    i32 idx = ld.mods.len;
    vec_push(&ld.mods, mod);
    return idx;
}

// Loads path (and its deps) into the loader; returns the module index
// or -1 on failure.
private i32 load_module(Loader* ld, str path) {
    str canon = canon_path(path);
    i32 existing = find_module(ld, canon);
    if existing >= 0 { free(canon.data); return existing; }

    FileData fd = file_read(path);
    if fd.data == null {
        eprint("tsmc: cannot read module '{}'\n", path);
        ld.failed = true;
        free(canon.data);
        return -1;
    }

    Module* mod = new(Module);
    u8* pc = alloc<u8>(path.len > 0 ? path.len : 1);
    if path.len > 0 { memcpy(pc, path.data, path.len); }
    mod.path.data = pc;
    mod.path.len = path.len;
    mod.canon = canon;
    mod.src_data = fd.data;
    mod.src_len = fd.len;
    mod.state = MOD_NEW;
    mod.ok = false;
    vec_init<i32>(&mod.dep_idx, 4);
    bump_init(&mod.arena);
    i32 my_idx = ld.mods.len;
    vec_push(&ld.mods, mod);

    str src;
    src.data = fd.data;
    src.len = fd.len;

    Parser p;
    parser_init(&p, src, &ld.diags, &mod.arena);
    Node* prog = parse_program(&p);
    Lower lw;
    lower_init(&lw, &mod.arena, &ld.diags);
    lower_program(&lw, prog);
    if ld.diags.n_errors > 0 {
        lower_destroy(&lw);
        parser_destroy(&p);
        ld.failed = true;
        return my_idx;
    }

    i32 rmark = gc_root_mark(&ld.vm.heap);
    Compiler co;
    compiler_init(&co, &ld.diags, &ld.vm.heap, vm_atoms(ld.vm), &mod.arena);
    str msrc;
    msrc.data = mod.src_data;
    msrc.len = mod.src_len;
    compiler_set_source(&co, msrc, mod.path);
    Vec<str> specs = vec_new<str>(4);
    mod.tmpl = compile_module(&co, prog, &specs);
    vm_add_template_root(ld.vm, mod.tmpl);
    gc_root_reset(&ld.vm.heap, rmark);

    // namespace object, rooted for the run
    mod.ns = vm_new_namespace(ld.vm);

    if ld.diags.n_errors > 0 {
        vec_free(&specs);
        lower_destroy(&lw);
        parser_destroy(&p);
        ld.failed = true;
        return my_idx;
    }

    mod.state = MOD_LOADED;

    // resolve and load dependencies (specifier views live in the arena)
    for i32 i = 0; i < specs.len; i++ {
        str spec = vec_get(&specs, i);
        // built-in modules (fs / path, incl. node: prefix) bind directly
        str bname = builtin_name(spec);
        if bname.data != null {
            i32 dep = load_builtin_module(ld, bname);
            if dep < 0 {
                eprint("tsmc: unknown built-in module '{}'\n", spec);
                ld.failed = true;
            }
            vec_push(&mod.dep_idx, dep);
            continue;
        }
        str resolved = resolve_specifier(mod.path, spec);
        if resolved.data == null {
            eprint("tsmc: cannot resolve '{}' from '{}'\n", spec, mod.path);
            ld.failed = true;
            vec_push(&mod.dep_idx, -1);
            continue;
        }
        i32 dep = load_module(ld, resolved);
        vec_push(&mod.dep_idx, dep);
        free(resolved.data);
    }

    vec_free(&specs);
    lower_destroy(&lw);
    parser_destroy(&p);
    return my_idx;
}

// --- evaluation --------------------------------------------------------------

// Post-order: evaluate dependencies, then this module's body. Returns
// 0 ok, 1 uncaught exception.
private i32 eval_module(Loader* ld, i32 idx) {
    Module* mod = vec_get(&ld.mods, idx);
    if mod.state == MOD_DONE || mod.state == MOD_EVALUATING { return 0; }
    mod.state = MOD_EVALUATING;
    for i32 i = 0; i < mod.dep_idx.len; i++ {
        i32 dep = vec_get(&mod.dep_idx, i);
        if dep < 0 { continue; }
        i32 st = eval_module(ld, dep);
        if st != 0 { return st; }
    }
    // call the module function with [ns, depNs...]
    i32 nargs = 1 + mod.dep_idx.len;
    Value* argv = alloc<Value>(nargs);
    *(argv) = value_cell(&mod.ns.head);
    for i32 i = 0; i < mod.dep_idx.len; i++ {
        i32 dep = vec_get(&mod.dep_idx, i);
        if dep >= 0 {
            *(argv + i + 1) = value_cell(&vec_get(&ld.mods, dep).ns.head);
        } else {
            *(argv + i + 1) = value_undefined();
        }
    }
    i32 st = vm_run_module_fn(ld.vm, mod.tmpl, argv, nargs);
    free(argv);
    mod.state = MOD_DONE;
    return st;
}

private void module_free(Module* mod) {
    free(mod.path.data);
    free(mod.canon.data);
    if mod.src_data != null { free(mod.src_data); }
    vec_free(&mod.dep_idx);
    bump_destroy(&mod.arena);
    free(mod);
}

// Loads and runs an entry module and its graph. Returns the exit code.
i32 module_run(VM* vm, str entry_path) {
    Loader ld;
    ld.vm = vm;
    vec_init<ModulePtr>(&ld.mods, 8);
    diags_init(&ld.diags);
    ld.failed = false;

    i32 entry = load_module(&ld, entry_path);
    i32 status = 0;
    if ld.failed || ld.diags.n_errors > 0 {
        if ld.diags.n_errors > 0 {
            str name;
            name.data = null;
            name.len = 0;
            diags_print(&ld.diags, entry_path, name);
        }
        status = 2;
    } else {
        status = eval_module(&ld, entry);
        if status == 0 { status = vm_run_event_loop(vm); }
    }

    for i32 i = 0; i < ld.mods.len; i++ {
        module_free(vec_get(&ld.mods, i));
    }
    vec_free(&ld.mods);
    diags_free(&ld.diags);
    return status;
}

// Detects module syntax in a source; used to pick the module path.
private bool has_module_syntax(str src) {
    DiagList d;
    diags_init(&d);
    Bump arena;
    bump_init(&arena);
    Parser p;
    parser_init(&p, src, &d, &arena);
    Node* prog = parse_program(&p);
    bool found = false;
    for i32 i = 0; i < prog.kids.len; i++ {
        i32 k = (*(prog.kids.items + i)).kind;
        if k == N_IMPORT || k == N_EXPORT { found = true; break; }
    }
    parser_destroy(&p);
    bump_destroy(&arena);
    diags_free(&d);
    return found;
}

// Drops the Windows \\?\ prefix that GetFinalPathNameByHandle prepends.
private str strip_unc(str p) {
    if p.len >= 4 && *(p.data) == '\\' && *(p.data + 1) == '\\'
        && *(p.data + 2) == '?' && *(p.data + 3) == '\\' {
        str r;
        r.data = p.data + 4;
        r.len = p.len - 4;
        return r;
    }
    return p;
}

// --- CommonJS require -------------------------------------------------------

private Value new_js_str(VM* vm, str s) {
    GcString* g = gc_new_string(&vm.heap, s);
    return value_cell(&g.head);
}

private str js_str_view(Value v) {
    return gc_string_view(value_as_string(v));
}

// Per-VM CJS module cache (canonical path -> module object), lazily made.
private JsObject* require_cache(VM* vm) {
    if vm.require_cache == null {
        vm.require_cache = js_new_object(&vm.heap, null);
    }
    return vm.require_cache;
}

private void require_throw_missing(VM* vm, str spec) {
    str_buf m;
    str_buf_init(&m);
    str_buf_add(&m, "Cannot find module '");
    str_buf_add(&m, spec);
    str_buf_add(&m, "'");
    Value err = vm_make_error(vm, ERR_ERROR, str_buf_to_str(&m));
    str_buf_free(&m);
    vm_push(vm, err);
    GcString* cs = gc_new_string(&vm.heap, "MODULE_NOT_FOUND");
    js_set_prop(value_as_object(err), atom_intern(&vm.atoms, "code"), value_cell(&cs.head));
    vm_pop(vm);
    vm_throw(vm, err);
}

private str null_str() {
    str r;
    r.data = null;
    r.len = 0;
    return r;
}

private str owned_str(str s) {
    u8* d = alloc<u8>(s.len > 0 ? s.len : 1);
    if s.len > 0 { memcpy(d, s.data, s.len); }
    str r;
    r.data = d;
    r.len = s.len;
    return r;
}

// dir + '/' + sub, normalized (`.`/`..`/duplicate separators collapsed).
private str path_under(str dir, str sub) {
    str_buf sb;
    str_buf_init(&sb);
    str_buf_add(&sb, dir);
    str_buf_add(&sb, "/");
    str_buf_add(&sb, sub);
    str combined = str_buf_to_str(&sb);
    str r = path_join(combined, "");
    str_buf_free(&sb);
    return r;
}

// LOAD_AS_FILE(base): base itself (only if a regular file, not a
// directory), then base + a source/data extension.
private str load_as_file(str base) {
    if file_there(base) && !path_is_dir(base) { return owned_str(base); }
    str[5] tries = { ".js", ".ts", ".cjs", ".mjs", ".json" };
    for i32 e = 0; e < 5; e++ {
        str c = try_candidate(base, tries[e]);
        if c.data != null { return c; }
    }
    return null_str();
}

// LOAD_INDEX(dir): dir/index.<ext>.
private str load_index(str dir) {
    str[5] tries = { "/index.js", "/index.ts", "/index.cjs", "/index.mjs", "/index.json" };
    for i32 e = 0; e < 5; e++ {
        str c = try_candidate(dir, tries[e]);
        if c.data != null { return c; }
    }
    return null_str();
}

// LOAD_AS_DIRECTORY(dir): package.json "main" (as file then index), else
// dir/index.<ext>.
private str load_as_dir(VM* vm, str dir) {
    str pj = path_under(dir, "package.json");
    if file_there(pj) {
        FileData fd = file_read(pj);
        if fd.data != null {
            str text;
            text.data = fd.data;
            text.len = fd.len;
            bool ok = false;
            Value j = builtins_json_parse(vm, text, &ok);
            free(fd.data);
            if ok && value_is_object(j) {
                Value mainv;
                if js_get_prop(value_as_object(j), atom_intern(&vm.atoms, "main"), &mainv)
                    && value_is_string(mainv) {
                    str mp = path_under(dir, gc_string_view(value_as_string(mainv)));
                    str r = load_as_file(mp);
                    if r.data == null { r = load_index(mp); }
                    free(mp.data);
                    if r.data != null { free(pj.data); return r; }
                }
            }
        }
    }
    free(pj.data);
    return load_index(dir);
}

// package.json "exports" resolution (conditional + subpath maps). Active
// conditions for a require() are node / require / default, matched in the
// object's key order (first match wins).

private bool is_require_condition(str k) {
    return str_equal(k, "require") || str_equal(k, "node") || str_equal(k, "default");
}

// Resolves an exports target (string / array fallback / conditions object)
// to a heap file path under `pkg_dir`, or {null,0}.
private str resolve_export_target(VM* vm, str pkg_dir, Value target) {
    if value_is_string(target) {
        str t = gc_string_view(value_as_string(target));
        if t.len < 2 || *(t.data) != '.' { return null_str(); }   // must be "./..."
        return path_under(pkg_dir, t);
    }
    if value_is_array(target) {
        JsObject* a = value_as_object(target);
        for i32 i = 0; i < a.elen; i++ {
            str r = resolve_export_target(vm, pkg_dir, js_array_get(a, i));
            if r.data != null {
                if file_there(r) { return r; }
                free(r.data);
            }
        }
        return null_str();
    }
    if value_is_object(target) {
        JsObject* keys = vm_own_keys(vm, target);
        vm_push(vm, value_cell(&keys.head));
        str result = null_str();
        for i32 i = 0; i < keys.elen; i++ {
            Value kv = js_array_get(keys, i);
            str k = gc_string_view(value_as_string(kv));
            if is_require_condition(k) {
                Value v;
                if js_get_prop(value_as_object(target), atom_intern(&vm.atoms, k), &v) {
                    str r = resolve_export_target(vm, pkg_dir, v);
                    if r.data != null { result = r; break; }
                }
            }
        }
        vm_pop(vm);
        return result;
    }
    return null_str();
}

// PACKAGE_EXPORTS_RESOLVE for a require: choose the target for `subpath`
// ("" -> ".", "sub" -> "./sub") and resolve it through the conditions.
// `exports` must be kept rooted by the caller.
private str resolve_exports(VM* vm, str pkg_dir, Value exports, str subpath) {
    Value target = value_undefined();
    bool have = false;
    if value_is_string(exports) || value_is_array(exports) {
        if subpath.len == 0 { target = exports; have = true; }
    } else if value_is_object(exports) {
        JsObject* eo = value_as_object(exports);
        JsObject* keys = vm_own_keys(vm, exports);
        vm_push(vm, value_cell(&keys.head));
        bool is_subpath_map = false;
        for i32 i = 0; i < keys.elen; i++ {
            str k = gc_string_view(value_as_string(js_array_get(keys, i)));
            if k.len > 0 && *(k.data) == '.' { is_subpath_map = true; break; }
        }
        vm_pop(vm);
        if is_subpath_map {
            str_buf kb;
            str_buf_init(&kb);
            str_buf_add(&kb, ".");
            if subpath.len > 0 {
                str_buf_add(&kb, "/");
                str_buf_add(&kb, subpath);
            }
            u32 katom = atom_intern(&vm.atoms, str_buf_to_str(&kb));
            str_buf_free(&kb);
            if js_get_prop(eo, katom, &target) { have = true; }
        } else if subpath.len == 0 {
            target = exports;   // a bare conditions object maps "."
            have = true;
        }
    }
    if !have { return null_str(); }
    return resolve_export_target(vm, pkg_dir, target);
}

// Resolves `subpath` within a located package directory. package.json
// "exports", when present, is authoritative (non-listed subpaths are
// blocked). Otherwise the legacy main/index (bare) or subpath-as-file/dir.
private str resolve_package(VM* vm, str pkg_dir, str subpath) {
    str pj = path_under(pkg_dir, "package.json");
    bool handled = false;
    str result = null_str();
    if file_there(pj) {
        FileData fd = file_read(pj);
        if fd.data != null {
            str text;
            text.data = fd.data;
            text.len = fd.len;
            bool ok = false;
            i32 rm = gc_root_mark(&vm.heap);
            Value j = builtins_json_parse(vm, text, &ok);
            gc_root(&vm.heap, j);
            if ok && value_is_object(j) {
                Value ev;
                if js_get_prop(value_as_object(j), atom_intern(&vm.atoms, "exports"), &ev)
                    && !value_is_undefined(ev) {
                    result = resolve_exports(vm, pkg_dir, ev, subpath);
                    handled = true;
                }
            }
            gc_root_reset(&vm.heap, rm);
            free(fd.data);
        }
    }
    free(pj.data);
    if handled { return result; }   // exports authoritative (may be null)
    if subpath.len == 0 { return load_as_dir(vm, pkg_dir); }
    str t = path_under(pkg_dir, subpath);
    str r = load_as_file(t);
    if r.data == null { r = load_as_dir(vm, t); }
    free(t.data);
    return r;
}

// Parent directory of `dir` (trailing separators trimmed); {null,0} at the
// filesystem root (no further ancestor).
private str parent_of(str dir) {
    i32 end = dir.len;
    while end > 0 && (*(dir.data + end - 1) == '/' || *(dir.data + end - 1) == '\\') { end--; }
    i32 sep = -1;
    for i32 i = 0; i < end; i++ {
        if *(dir.data + i) == '/' || *(dir.data + i) == '\\' { sep = i; }
    }
    if sep < 0 { return null_str(); }
    // keep a lone root ("/" or "C:/") rather than emptying it
    i32 plen = sep == 0 ? 1 : sep;
    str p;
    p.data = dir.data;
    p.len = plen;
    return owned_str(p);
}

// A bare specifier's package name is its first segment (or first two for a
// `@scope/name`); the remainder is the subpath.
private void split_pkg(str spec, str* pkg, str* subpath) {
    i32 slashes_needed = (spec.len > 0 && *(spec.data) == '@') ? 2 : 1;
    i32 seen = 0;
    i32 cut = spec.len;
    for i32 i = 0; i < spec.len; i++ {
        if *(spec.data + i) == '/' {
            seen++;
            if seen == slashes_needed { cut = i; break; }
        }
    }
    pkg.data = spec.data;
    pkg.len = cut;
    if cut < spec.len {
        subpath.data = spec.data + cut + 1;
        subpath.len = spec.len - cut - 1;
    } else {
        subpath.data = spec.data;
        subpath.len = 0;
    }
}

// LOAD_NODE_MODULES: walk up from `start_dir` trying
// <d>/node_modules/<pkg>[/<subpath>] at each level. Heap path or null.
private str load_node_modules(VM* vm, str start_dir, str pkg, str subpath) {
    str cur = owned_str(start_dir);
    str result = null_str();
    i32 guard = 0;
    while guard < 64 {
        guard++;
        str nm = path_under(cur, "node_modules");
        str base = path_under(nm, pkg);
        str f = null_str();
        bool stop = false;
        if path_is_dir(base) {
            // package directory found here: resolve within it — exports
            // (authoritative: non-listed subpaths are blocked), else the
            // legacy main / index / subpath-as-file. Stop walking.
            f = resolve_package(vm, base, subpath);
            stop = true;
        } else {
            // no package directory: try base[/subpath] as a bare file
            str target;
            if subpath.len > 0 { target = path_under(base, subpath); }
            else { target = owned_str(base); }
            f = load_as_file(target);
            free(target.data);
        }
        free(base.data);
        free(nm.data);
        if f.data != null { result = f; break; }   // cur freed after the loop
        if stop { break; }
        str parent = parent_of(cur);
        free(cur.data);
        cur = parent;                                // {null,0} at the root
        if cur.data == null { break; }
    }
    if cur.data != null { free(cur.data); }
    return result;
}

private bool spec_is_absolute(str s) {
    if s.len >= 1 && (*(s.data) == '/' || *(s.data) == '\\') { return true; }
    when os(windows) {
        if s.len >= 3 {
            u8 c = *(s.data);
            bool letter = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z');
            if letter && *(s.data + 1) == ':' { return true; }
        }
    }
    return false;
}

private bool spec_is_dot(str s) {
    if s.len >= 2 && *(s.data) == '.' && (*(s.data + 1) == '/' || *(s.data + 1) == '\\') { return true; }
    if s.len >= 3 && *(s.data) == '.' && *(s.data + 1) == '.'
        && (*(s.data + 2) == '/' || *(s.data + 2) == '\\') { return true; }
    return false;
}

// Full CJS resolution of `spec` from a module at `importer_path`. Returns a
// heap file path (caller frees .data) or {null,0} if unresolved.
private str resolve_require(VM* vm, str importer_path, str spec) {
    str idir = dir_of(importer_path);   // includes trailing separator
    if spec_is_absolute(spec) {
        str r = load_as_file(spec);
        if r.data == null { r = load_as_dir(vm, spec); }
        return r;
    }
    if spec_is_dot(spec) {
        str base = path_under(idir, spec);
        str r = load_as_file(base);
        if r.data == null { r = load_as_dir(vm, base); }
        free(base.data);
        return r;
    }
    // bare specifier -> node_modules walk
    str pkg;
    str subpath;
    split_pkg(spec, &pkg, &subpath);
    // trim idir's trailing separator for a clean start point
    str start = idir;
    if start.len > 1 && (*(start.data + start.len - 1) == '/' || *(start.data + start.len - 1) == '\\') {
        start.len = start.len - 1;
    }
    return load_node_modules(vm, start, pkg, subpath);
}

// A `require` bound to the requiring module's path (env0), so nested
// requires resolve relative to their own module's directory.
private Value make_require_fn(VM* vm, str module_path) {
    Value pv = new_js_str(vm, module_path);
    vm_push(vm, pv);
    JsNative* n = js_new_native(&vm.heap, &nat_require, "require");
    n.env0 = pv;
    vm_pop(vm);
    return value_cell(&n.head);
}

// Built-in modules implemented as embedded JS source (compiled+run once),
// as opposed to the natively-built namespaces. {null,0} if not one.
private str builtin_js_source(str name) {
    if str_equal(name, "stream") { return node_stream_source(); }
    if str_equal(name, "assert") { return node_assert_source(); }
    return null_str();
}

// Compiles+runs an embedded JS built-in as a CJS module and caches it by
// "builtin:<name>". Its `require` reaches the other built-ins (e.g. the
// stream source requires 'events'). Returns module.exports.
private Value run_js_builtin(VM* vm, str name, str src) {
    str_buf kb;
    str_buf_init(&kb);
    str_buf_add(&kb, "builtin:");
    str_buf_add(&kb, name);
    str canon = raw_from(&kb);
    str_buf_free(&kb);
    u32 key = atom_intern(&vm.atoms, canon);
    u32 exports_atom = atom_intern(&vm.atoms, "exports");
    JsObject* cache = require_cache(vm);
    Value cached;
    if js_get_prop(cache, key, &cached) {
        free(canon.data);
        Value ex;
        if value_is_object(cached) && js_get_prop(value_as_object(cached), exports_atom, &ex) { return ex; }
        return value_undefined();
    }
    free(canon.data);

    i32 rm = gc_root_mark(&vm.heap);
    JsObject* module = js_new_object(&vm.heap, vm.object_proto);
    gc_root(&vm.heap, value_cell(&module.head));
    JsObject* exports = js_new_object(&vm.heap, vm.object_proto);
    js_set_prop(module, exports_atom, value_cell(&exports.head));
    js_set_prop(cache, key, value_cell(&module.head));

    DiagList d;
    diags_init(&d);
    Bump arena;
    bump_init(&arena);
    Parser p;
    parser_init(&p, src, &d, &arena);
    Node* prog = parse_program(&p);
    Lower lw;
    lower_init(&lw, &arena, &d);
    lower_program(&lw, prog);
    if d.n_errors == 0 {
        i32 cm = gc_root_mark(&vm.heap);
        Compiler co;
        compiler_init(&co, &d, &vm.heap, &vm.atoms, &arena);
        compiler_set_source(&co, src, name);
        FnTemplate* t = compile_cjs_module(&co, prog);
        vm_add_template_root(vm, t);
        gc_root_reset(&vm.heap, cm);
        if d.n_errors == 0 {
            Value reqfn = make_require_fn(vm, name);
            gc_root(&vm.heap, reqfn);
            Value dnv = new_js_str(vm, name);
            gc_root(&vm.heap, dnv);
            Value[5] cjs_args;
            cjs_args[0] = value_cell(&exports.head);
            cjs_args[1] = reqfn;
            cjs_args[2] = value_cell(&module.head);
            cjs_args[3] = dnv;
            cjs_args[4] = dnv;
            JsFunction* f = js_new_function(&vm.heap, t, 0);
            ignore vm_call_value(vm, value_cell(&f.head), value_undefined(), &cjs_args[0], 5);
        } else {
            diags_print(&d, name, name);
        }
    } else {
        diags_print(&d, name, name);
    }
    parser_destroy(&p);
    lower_destroy(&lw);
    Value result = value_undefined();
    if !vm.has_pending {
        Value ex;
        if js_get_prop(module, exports_atom, &ex) { result = ex; }
    }
    gc_root_reset(&vm.heap, rm);
    bump_destroy(&arena);
    diags_free(&d);
    return result;
}

// Namespace wrapper for an embedded JS built-in: default = exports, plus
// each of exports' own keys as a named export (so ESM `import { X }` works).
private JsObject* js_builtin_namespace(VM* vm, Value exports) {
    JsObject* ns = js_new_object(&vm.heap, null);
    gc_root(&vm.heap, value_cell(&ns.head));
    props_set_desc(&ns.props, atom_intern(&vm.atoms, "default"), exports, PROP_DEFAULT);
    JsObject* keys = vm_own_keys(vm, exports);
    vm_push(vm, value_cell(&keys.head));
    for i32 i = 0; i < keys.elen; i++ {
        Value kv = js_array_get(keys, i);
        u32 katom = atom_intern(&vm.atoms, gc_string_view(value_as_string(kv)));
        Value v;
        if vm_get_prop_value(vm, exports, katom, &v) {
            props_set_desc(&ns.props, katom, v, PROP_DEFAULT);
        }
    }
    vm_pop(vm);
    return ns;
}

// Synchronously loads and evaluates the CJS module named by `spec` from a
// module at `importer_path`; returns its `module.exports`.
Value module_require(VM* vm, str importer_path, str spec) {
    // 1. built-in module (fs / path / os / ..., incl. node: prefix)
    str bname = builtin_name(spec);
    if bname.data != null {
        JsObject* ns = builtins_node_module(vm, bname);
        if ns != null {
            Value def;
            if js_get_prop(ns, atom_intern(&vm.atoms, "default"), &def) { return def; }
            return value_cell(&ns.head);
        }
        // JS-source built-in (e.g. stream)
        str jsrc = builtin_js_source(bname);
        if jsrc.data != null { return run_js_builtin(vm, bname, jsrc); }
    }
    // 2. resolve (relative/absolute file, or a node_modules package)
    str resolved = resolve_require(vm, importer_path, spec);
    if resolved.data == null {
        require_throw_missing(vm, spec);
        return value_undefined();
    }
    str canon = canon_path(resolved);
    u32 key = atom_intern(&vm.atoms, canon);
    u32 exports_atom = atom_intern(&vm.atoms, "exports");
    JsObject* cache = require_cache(vm);

    // 3. cache hit -> current module.exports
    Value cached;
    if js_get_prop(cache, key, &cached) {
        free(resolved.data);
        free(canon.data);
        Value ex;
        if value_is_object(cached) && js_get_prop(value_as_object(cached), exports_atom, &ex) { return ex; }
        return value_undefined();
    }

    // 4. read source
    FileData fd = file_read(resolved);
    if fd.data == null {
        require_throw_missing(vm, spec);
        free(resolved.data);
        free(canon.data);
        return value_undefined();
    }

    // 4b. a .json file: parse and cache the value directly (no compilation)
    bool is_json = resolved.len >= 5
        && *(resolved.data + resolved.len - 5) == '.'
        && *(resolved.data + resolved.len - 4) == 'j'
        && *(resolved.data + resolved.len - 3) == 's'
        && *(resolved.data + resolved.len - 2) == 'o'
        && *(resolved.data + resolved.len - 1) == 'n';
    if is_json {
        str text;
        text.data = fd.data;
        text.len = fd.len;
        bool ok = false;
        i32 jm = gc_root_mark(&vm.heap);
        Value parsed = builtins_json_parse(vm, text, &ok);
        gc_root(&vm.heap, parsed);
        Value ret = value_undefined();
        if ok {
            JsObject* jm2 = js_new_object(&vm.heap, vm.object_proto);
            js_set_prop(jm2, exports_atom, parsed);
            js_set_prop(cache, key, value_cell(&jm2.head));
            ret = parsed;
        }
        gc_root_reset(&vm.heap, jm);
        free(fd.data);
        free(resolved.data);
        free(canon.data);
        if !ok { vm_throw_error(vm, ERR_SYNTAX, "invalid JSON in required module"); }
        return ret;
    }

    // 5. module + exports; cache BEFORE running (circular require sees the
    //    partial exports)
    i32 rm = gc_root_mark(&vm.heap);
    JsObject* module = js_new_object(&vm.heap, vm.object_proto);
    gc_root(&vm.heap, value_cell(&module.head));
    JsObject* exports = js_new_object(&vm.heap, vm.object_proto);
    js_set_prop(module, exports_atom, value_cell(&exports.head));
    js_set_prop(module, atom_intern(&vm.atoms, "id"), new_js_str(vm, canon));
    js_set_prop(cache, key, value_cell(&module.head));

    str fdir = dir_of(resolved);
    str dname = fdir;
    if dname.len > 1 { dname.len = dname.len - 1; }   // drop trailing sep

    // 6. compile as a CJS wrapper function and run it
    DiagList d;
    diags_init(&d);
    Bump arena;
    bump_init(&arena);
    str src;
    src.data = fd.data;
    src.len = fd.len;
    Parser p;
    parser_init(&p, src, &d, &arena);
    Node* prog = parse_program(&p);
    Lower lw;
    lower_init(&lw, &arena, &d);
    lower_program(&lw, prog);

    if d.n_errors == 0 {
        i32 cm = gc_root_mark(&vm.heap);
        Compiler co;
        compiler_init(&co, &d, &vm.heap, &vm.atoms, &arena);
        // owned source name (persists with the forever-rooted template)
        u8* nb = alloc<u8>(resolved.len > 0 ? resolved.len : 1);
        if resolved.len > 0 { memcpy(nb, resolved.data, resolved.len); }
        str owned_name;
        owned_name.data = nb;
        owned_name.len = resolved.len;
        compiler_set_source(&co, src, owned_name);
        FnTemplate* t = compile_cjs_module(&co, prog);
        vm_add_template_root(vm, t);
        gc_root_reset(&vm.heap, cm);

        if d.n_errors == 0 {
            Value reqfn = make_require_fn(vm, resolved);
            gc_root(&vm.heap, reqfn);
            Value dnv = new_js_str(vm, dname);
            gc_root(&vm.heap, dnv);
            Value fnv = new_js_str(vm, resolved);
            gc_root(&vm.heap, fnv);
            Value[5] cjs_args;
            cjs_args[0] = value_cell(&exports.head);
            cjs_args[1] = reqfn;
            cjs_args[2] = value_cell(&module.head);
            cjs_args[3] = dnv;
            cjs_args[4] = fnv;
            JsFunction* f = js_new_function(&vm.heap, t, 0);
            ignore vm_call_value(vm, value_cell(&f.head), value_undefined(), &cjs_args[0], 5);
        } else {
            diags_print(&d, resolved, owned_name);
            vm_throw_error(vm, ERR_SYNTAX, "error compiling required module");
        }
    } else {
        diags_print(&d, resolved, resolved);
        vm_throw_error(vm, ERR_SYNTAX, "error parsing required module");
    }

    parser_destroy(&p);
    lower_destroy(&lw);

    // 7. result = final module.exports (unless the body threw)
    Value result = value_undefined();
    if !vm.has_pending {
        Value ex;
        if js_get_prop(module, exports_atom, &ex) { result = ex; }
    }
    gc_root_reset(&vm.heap, rm);
    bump_destroy(&arena);
    diags_free(&d);
    free(fd.data);
    free(resolved.data);
    free(canon.data);
    return result;
}

private Value nat_require(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = cast(VM*, vmp);
    Value specv = argc > 0 ? *(args) : value_undefined();
    if !value_is_string(specv) {
        vm_throw_error(vm, ERR_TYPE, "require path must be a string");
        return value_undefined();
    }
    str base = js_str_view(value_as_native(callee).env0);
    return module_require(vm, base, js_str_view(specv));
}

// CLI entry: module graph if the file uses import/export, else script.
i32 module_run_entry(VM* vm, str src, str path) {
    // __filename / __dirname for the entry file (absolute, entry-scoped).
    str fname = canon_path(path);
    str fclean = strip_unc(fname);
    str dir = dir_of(fclean);
    str dname = dir;
    if dname.len > 1 { dname.len = dname.len - 1; }  // drop trailing separator
    builtins_set_entry(vm, fclean, dname);
    free(fname.data);

    if has_module_syntax(src) {
        return module_run(vm, path);
    }
    // plain script: expose a CommonJS `require` bound to the entry file
    vm_set_global(vm, "require", make_require_fn(vm, path));
    return vm_run_source(vm, src, path);
}

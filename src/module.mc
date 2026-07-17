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
import vm;
import builtins;

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
when !os(windows) {
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
    return vm_run_source(vm, src, path);
}

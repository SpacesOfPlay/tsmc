// compiler.mc — lowered AST to bytecode.
//
// Scope analysis is fused with emission: an inner-name scan decides
// which bindings become heap boxes, var hoisting runs per function,
// let/const get TDZ holes at block entry. Classes compile against a
// hidden %super binding; destructuring desugars through temp slots;
// optional chains share a nil exit. See doc/DESIGN_bytecode.md and
// doc/PLAN_M7_modern.md.

import vec;
import str;
import map;
import diag;
import lexer;
import ast;
import value;
import gc;
import atom;
import bytecode;
import regex;
import bump;
import object;
import bigint;

// Numbers class declarations across every compile in the process, so a
// private name is the declaring class's own.
i32 g_class_seq = 0;

struct CBind {
    str name;
    i32 slot;
    i32 depth;
    bool is_cell;
    bool is_const;
    bool tdz;
    bool exported;   // module-scope binding with a live export
}

struct CUp {
    str name;
    bool is_const;
    bool tdz;
    bool exported;
}

// A pending break/continue jump, tagged with the loop it targets so an
// inner loop never patches a jump aimed at an outer (labeled) loop.
struct BrkJump {
    i32 at;
    i32 loop_id;
}

struct LoopCtx {
    bool is_loop;      // false for switch and labeled blocks
    str label;
    i32 id;
    i32 fin_depth;
}

// Cleanup an early exit (return, or a break/continue crossing it) has to run:
// either a source-level `finally` block, or closing a for-of iterator.
struct FinEntry {
    Node* fin;        // null means "close the iterator in iter_slot"
    i32 iter_slot;
    i32 done_slot;
}

struct FScope {
    FScope* parent;
    Chunk ch;
    Vec<CBind> binds;
    Vec<CUp> ups;
    StrMap<i32> inner;   // names mentioned inside nested functions
    i32 n_slots;
    i32 cur_slots;
    i32 depth;
    bool is_arrow;
    bool has_rest;
    bool is_gen;
    bool is_async;
    bool needs_arguments;   // references `arguments`; build it at call time
    bool super_call_ok;     // a derived class constructor: super() is allowed
    bool static_home;       // a static member: `super.x` is the parent class
    i32 loop_floor;         // loops below this index belong to an enclosing
                            // scope a break or continue may not reach
    Vec<BrkJump> break_jumps;
    Vec<BrkJump> cont_jumps;
    Vec<LoopCtx> loops;
    Vec<FinEntry> finallys;
    i32 loop_id_counter;
}

// A name imported into the current module: read live from a
// dependency namespace slot.
// A private name a class declares: kind 0 is a field, 1 an instance
// method or accessor, 2 a static one. The kind chooses the error a
// foreign receiver gets.
struct PrivName {
    str name;
    i32 kind;
    i32 acc;         // NF_GETTER or NF_SETTER for an accessor, else 0
    bool is_static;
    bool paired;     // an accessor whose other half was seen
}

// The private names one class declares, the number that makes them its
// own and the class's own name for messages; the compiler keeps a stack
// of these while inside class bodies.
struct PrivScope {
    Vec<PrivName> names;
    i32 id;
    str class_name;
}

struct ModImport {
    str slot_name;   // "%modK"
    str prop;        // exported name in the source module
    str spec;        // the import's specifier, for messages
    Value msg;       // the read-failure message, built on first use
    bool has_msg;
}

// What a module imports and re-exports, by name, for the loader's link
// check (see module.mc). The names are views into the module's arena.
struct LinkImport {
    str spec;
    str name;        // the imported name; "default" for a default import
}

struct LinkIndirect {
    str exported;    // the name this module exports it under
    str spec;        // the module it comes from
    str name;        // the name there
}

struct ModLinks {
    Vec<str> locals;              // exports of this module's own bindings
    Vec<LinkImport> imports;      // named and default imports
    Vec<LinkIndirect> indirect;   // export { a as b } from, and export { x } of an import
    Vec<str> stars;               // export * from
}

void links_init(ModLinks* l) {
    vec_init<str>(&l.locals, 4);
    vec_init<LinkImport>(&l.imports, 4);
    vec_init<LinkIndirect>(&l.indirect, 2);
    vec_init<str>(&l.stars, 1);
}

void links_free(ModLinks* l) {
    vec_free(&l.locals);
    vec_free(&l.imports);
    vec_free(&l.indirect);
    vec_free(&l.stars);
}

// One exported name of a module-scope binding; a binding exported under
// several names chains through `next`.
struct ExportName {
    str exported;
    i32 next;   // index into Compiler.export_names, or -1
}

struct Compiler {
    DiagList* diags;
    GcHeap* heap;
    AtomTable* atoms;
    Bump* arena;
    FScope* cur;
    str pending_label;
    bool in_module;
    bool strict;        // strict-mode code: modules, classes, after "use strict"
    bool static_this;   // inside a static block / field: `this` is the class ctor
    bool next_static_home;  // the next function compiled is a static member
    Vec<str> outer_names;       // names the next block's lexical declarations may
                                // not repeat: the parameters of its function, or
                                // the catch parameter
    bool outer_is_body;         // the next block is a function body
    bool next_is_derived_ctor;  // the next function compiled is a derived
                                // class constructor
    bool in_static_block;       // directly inside a class static block
    bool in_params;             // compiling parameter defaults
    StrMap<ModImport> mod_imports;   // valid while in_module
    str ns_name;                     // the module namespace binding
    StrMap<i32> export_heads;        // local name -> first ExportName
    Vec<ExportName> export_names;
    Vec<PrivScope> priv_scopes;      // enclosing class bodies, innermost last
    str src;        // source text, for line/col of stack-trace positions
    str src_name;   // source filename
    i32* line_starts;   // byte offset where each line of src begins
    i32 n_lines;
}

void compiler_init(Compiler* co, DiagList* diags, GcHeap* heap, AtomTable* atoms, Bump* arena) {
    co.diags = diags;
    co.heap = heap;
    co.atoms = atoms;
    co.arena = arena;
    co.cur = null;
    co.pending_label.data = null;
    co.pending_label.len = 0;
    co.in_module = false;
    co.strict = false;
    co.static_this = false;
    co.next_static_home = false;
    vec_init<str>(&co.outer_names, 4);
    co.outer_is_body = false;
    co.next_is_derived_ctor = false;
    co.in_static_block = false;
    co.in_params = false;
    strmap_init<ModImport>(&co.mod_imports);
    co.ns_name = "";
    strmap_init<i32>(&co.export_heads);
    vec_init<ExportName>(&co.export_names, 8);
    vec_init<PrivScope>(&co.priv_scopes, 4);
    co.src.data = null;
    co.src.len = 0;
    co.src_name = "";
    co.line_starts = null;
    co.n_lines = 0;
}

// Source text + filename for stack-trace positions. The line table makes
// a position lookup a binary search; scanning from the start of the file
// for each one made compilation quadratic in file size.
void compiler_set_source(Compiler* co, str src, str src_name) {
    co.src = src;
    co.src_name = src_name;
    i32 n = 1;
    for i32 i = 0; i < src.len; i++ {
        if *(src.data + i) == '\n' { n++; }
    }
    i32* starts = cast(i32*, bump_alloc(co.arena, n * 4));
    *starts = 0;
    i32 k = 1;
    for i32 i = 0; i < src.len; i++ {
        if *(src.data + i) == '\n' {
            *(starts + k) = i + 1;
            k++;
        }
    }
    co.line_starts = starts;
    co.n_lines = n;
}

private void cerror(Compiler* co, Node* n, str msg) {
    diag_add(co.diags, DIAG_ERROR, n.span, msg);
}

// Records the source position of a node at the current code offset.
// Line and column count the way diag_line_col does: the last line that
// starts at or before the offset, and bytes since its start, both 1-based.
private void emit_pos(Compiler* co, Node* n) {
    if co.src.data == null { return; }
    i32 off = n.span.start;
    if off > co.src.len { off = co.src.len; }
    i32 lo = 0;
    i32 hi = co.n_lines - 1;
    while lo < hi {
        i32 mid = (lo + hi + 1) / 2;
        if *(co.line_starts + mid) <= off { lo = mid; } else { hi = mid - 1; }
    }
    ch_record_pos(&co.cur.ch, lo + 1, off - *(co.line_starts + lo) + 1);
}

private str take_label(Compiler* co) {
    str l = co.pending_label;
    co.pending_label.data = null;
    co.pending_label.len = 0;
    return l;
}

// --- scopes -------------------------------------------------------------

private void fscope_init(FScope* fs, FScope* parent, bool is_arrow) {
    fs.parent = parent;
    chunk_init(&fs.ch);
    vec_init<CBind>(&fs.binds, 16);
    vec_init<CUp>(&fs.ups, 4);
    strmap_init<i32>(&fs.inner);
    fs.n_slots = 0;
    fs.cur_slots = 0;
    fs.depth = 0;
    fs.is_arrow = is_arrow;
    fs.has_rest = false;
    fs.is_gen = false;
    fs.is_async = false;
    fs.needs_arguments = false;
    fs.super_call_ok = false;
    // an arrow has no home object of its own; it uses the one around it
    fs.static_home = is_arrow && parent != null ? parent.static_home : false;
    fs.loop_floor = 0;
    vec_init<BrkJump>(&fs.break_jumps, 8);
    vec_init<BrkJump>(&fs.cont_jumps, 8);
    vec_init<LoopCtx>(&fs.loops, 4);
    vec_init<FinEntry>(&fs.finallys, 4);
    fs.loop_id_counter = 1;
}

private void fscope_free(FScope* fs) {
    vec_free(&fs.binds);
    vec_free(&fs.ups);
    strmap_free<i32>(&fs.inner);
    vec_free(&fs.break_jumps);
    vec_free(&fs.cont_jumps);
    vec_free(&fs.loops);
    vec_free(&fs.finallys);
}

private i32 alloc_slot(FScope* fs) {
    i32 s = fs.cur_slots;
    fs.cur_slots++;
    if fs.cur_slots > fs.n_slots { fs.n_slots = fs.cur_slots; }
    return s;
}

private i32 declare(Compiler* co, str name, bool is_const, bool tdz) {
    FScope* fs = co.cur;
    CBind b;
    b.name = name;
    b.slot = alloc_slot(fs);
    b.depth = fs.depth;
    b.is_cell = strmap_get<i32>(&fs.inner, name) != null;
    b.is_const = is_const;
    b.tdz = tdz;
    b.exported = co.in_module && fs.parent == null && fs.depth == 0
        && strmap_get<i32>(&co.export_heads, name) != null;
    vec_push(&fs.binds, b);
    return fs.binds.len - 1;
}

private i32 find_local(FScope* fs, str name) {
    for i32 i = fs.binds.len - 1; i >= 0; i-- {
        CBind b = vec_get(&fs.binds, i);
        if str_equal(b.name, name) { return i; }
    }
    return -1;
}

private i32 resolve_upval(FScope* fs, str name) {
    if fs.parent == null { return -1; }
    for i32 i = 0; i < fs.ups.len; i++ {
        CUp u = vec_get(&fs.ups, i);
        if str_equal(u.name, name) { return i; }
    }
    i32 li = find_local(fs.parent, name);
    if li >= 0 {
        CBind b = vec_get(&fs.parent.binds, li);
        CUp u;
        u.name = name;
        u.is_const = b.is_const;
        u.tdz = b.tdz;
        u.exported = b.exported;
        vec_push(&fs.ups, u);
        TmplUpval tu;
        tu.from_parent_slot = true;
        tu.index = b.slot;
        vec_push(&fs.ch.upvals, tu);
        return fs.ups.len - 1;
    }
    i32 pi = resolve_upval(fs.parent, name);
    if pi < 0 { return -1; }
    CUp pu = vec_get(&fs.parent.ups, pi);
    CUp u;
    u.name = name;
    u.is_const = pu.is_const;
    u.tdz = pu.tdz;
    u.exported = pu.exported;
    vec_push(&fs.ups, u);
    TmplUpval tu;
    tu.from_parent_slot = false;
    tu.index = pi;
    vec_push(&fs.ch.upvals, tu);
    return fs.ups.len - 1;
}

// --- constants ------------------------------------------------------------

private Value num_value(f64 v) {
    i32 i = cast(i32, v);
    if cast(f64, i) == v {
        if v == 0.0 && 1.0 / v < 0.0 { return value_number(v); }
        return value_int(i);
    }
    return value_number(v);
}

// Compile-time GC values stay rooted until the VM owns the templates.
private i32 str_const(Compiler* co, str s) {
    GcString* gs = gc_new_string(co.heap, s);
    Value v = value_cell(&gs.head);
    gc_root(co.heap, v);
    return ch_add_const(&co.cur.ch, v);
}

private i32 name_const(Compiler* co, str name) {
    u32 a = atom_intern(co.atoms, name);
    return ch_add_const(&co.cur.ch, value_int(cast(i32, a)));
}

// import.meta.url as a file:// URL of the current module, built at compile
// time from its path (backslashes normalized, a leading slash before a
// Windows drive letter).
private i32 import_meta_url_const(Compiler* co) {
    str p = co.src_name;
    str_buf sb;
    str_buf_init(&sb);
    str_buf_add(&sb, "file://");
    if p.len == 0 || (*(p.data) != '/' && *(p.data) != '\\') {
        str_buf_add_byte(&sb, cast(u8, '/'));
    }
    for i32 i = 0; i < p.len; i++ {
        u8 c = *(p.data + i);
        if c == cast(u8, '\\') { c = cast(u8, '/'); }
        str_buf_add_byte(&sb, c);
    }
    i32 idx = str_const(co, str_buf_to_str(&sb));
    str_buf_free(&sb);
    return idx;
}

// import.meta.filename and .dirname: the module's own path, and the
// directory holding it. An ESM file has no __dirname, so these are how it
// finds a file beside itself.
private i32 import_meta_path_const(Compiler* co, bool dir_only) {
    str p = co.src_name;
    i32 end = p.len;
    if dir_only {
        i32 sep = -1;
        for i32 i = 0; i < p.len; i++ {
            u8 c = *(p.data + i);
            if c == '/' || c == cast(u8, '\\') { sep = i; }
        }
        end = sep < 0 ? 0 : sep;   // no trailing separator, as node has none
    }
    str v;
    v.data = p.data;
    v.len = end;
    return str_const(co, v);
}

// Numeric property keys stringify the JS way: 1, not 1.0.
// The property-name text of a numeric key, copied into the arena so it can
// outlive this call as a function's inferred name.
private str num_key_text(Compiler* co, f64 num) {
    i64 iv = cast(i64, num);
    string s;
    if cast(f64, iv) == num { s = format("{}", iv); } else { s = format("{}", num); }
    str view = s;
    u8* copy = cast(u8*, bump_alloc(co.arena, view.len));
    memcpy(copy, view.data, view.len);
    free(s);
    str r;
    r.data = copy;
    r.len = view.len;
    return r;
}

// An accessor's function is named "get x" / "set x". Built in the arena so it
// outlives this call as the function's inferred name.
// The name an anonymous method or field initializer takes from its key.
// A private name keeps its '#'; a computed key has none at compile time.
private str key_name_text(Compiler* co, Node* key) {
    if key == null { return ""; }
    if key.kind == N_NUMBER { return num_key_text(co, key.num); }
    if key.kind == N_PRIVATE_IDENT {
        string s = format("#{}", key.name);
        str view = s;
        u8* copy = cast(u8*, bump_alloc(co.arena, view.len));
        memcpy(copy, view.data, view.len);
        free(s);
        str r;
        r.data = copy;
        r.len = view.len;
        return r;
    }
    if key.kind == N_IDENT || key.kind == N_STRING { return key.name; }
    return "";
}

private str accessor_name(Compiler* co, str prefix, Node* key) {
    str base = key_name_text(co, key);
    if base.len == 0 { return base; }
    string s = format("{} {}", prefix, base);
    str view = s;
    u8* copy = cast(u8*, bump_alloc(co.arena, view.len));
    memcpy(copy, view.data, view.len);
    free(s);
    str r;
    r.data = copy;
    r.len = view.len;
    return r;
}

private i32 num_key_const(Compiler* co, f64 num) {
    i64 iv = cast(i64, num);
    string s;
    if cast(f64, iv) == num {
        s = format("{}", iv);
    } else {
        s = format("{}", num);
    }
    i32 ci = name_const(co, s);
    free(s);
    return ci;
}

// Private names are stored under "%#name@class": the '%' hides them from
// enumeration, the '#' keeps them clear of the engine's %-internals, and
// the class number makes the name the declaring class's own. A method or
// accessor adds "@i:Class" (static: "@s:Class"), which is what its
// foreign-receiver error names. A name resolves through the enclosing
// classes, innermost first, like a binding.
private i32 private_key_const(Compiler* co, Node* at, str name) {
    i32 id = 0 - 1;
    i32 kind = 0;
    str cname = "";
    for i32 i = co.priv_scopes.len - 1; i >= 0 && id < 0; i-- {
        PrivScope ps = vec_get(&co.priv_scopes, i);
        for i32 j = 0; j < ps.names.len; j++ {
            PrivName pn = vec_get(&ps.names, j);
            if str_equal(pn.name, name) {
                id = ps.id;
                kind = pn.kind;
                cname = ps.class_name;
                break;
            }
        }
    }
    if id < 0 {
        cerror(co, at, "private name is not declared in an enclosing class");
        id = 0;
    }
    string s;
    if kind == 0 {
        s = format("%#{}@{}", name, id);
    } else if kind == 1 {
        s = format("%#{}@{}@i:{}", name, id, cname);
    } else {
        s = format("%#{}@{}@s:{}", name, id, cname);
    }
    str view = s;
    u8* copy = cast(u8*, bump_alloc(co.arena, view.len));
    memcpy(copy, view.data, view.len);
    free(s);
    str m;
    m.data = copy;
    m.len = view.len;
    return name_const(co, m);
}

private i32 prop_key_const(Compiler* co, Node* key) {
    if key.kind == N_NUMBER { return num_key_const(co, key.num); }
    if key.kind == N_PRIVATE_IDENT { return private_key_const(co, key, key.name); }
    return name_const(co, key.name);
}

private str hidden_name(Compiler* co, str prefix, i32 n) {
    string s = format("{}{}", prefix, n);
    str view = s;
    u8* copy = cast(u8*, bump_alloc(co.arena, view.len + 1));
    memcpy(copy, view.data, view.len);
    str r;
    r.data = copy;
    r.len = view.len;
    free(s);
    return r;
}

// --- inner-name scan ---------------------------------------------------------

private void scan_all_names(StrMap<i32>* set, Node* n) {
    if n == null { return; }
    if n.kind == N_IDENT && n.name.len > 0 {
        strmap_set<i32>(set, n.name, 1);
    }
    if n.kind == N_THIS {
        strmap_set<i32>(set, "this", 1);
    }
    if n.kind == N_NEW_TARGET {
        strmap_set<i32>(set, "%newtarget", 1);
    }
    if n.kind == N_SUPER {
        strmap_set<i32>(set, "%super", 1);
    }
    scan_all_names(set, n.a);
    scan_all_names(set, n.b);
    scan_all_names(set, n.c);
    scan_all_names(set, n.d);
    for i32 i = 0; i < n.kids.len; i++ {
        scan_all_names(set, *(n.kids.items + i));
    }
}

// Collects names used by nested functions of n (not n itself).
private void scan_inner(StrMap<i32>* set, Node* n, bool root) {
    if n == null { return; }
    if n.kind == N_FUNCTION && !root {
        scan_all_names(set, n);
        return;
    }
    // An instance field initializer is hoisted into the constructor, so its
    // identifiers are captured by that (possibly synthesized) function just
    // like a method body. Treat it as inner-function code so the enclosing
    // scope cellifies anything it closes over. Its computed key is evaluated
    // where the class is, so that is scanned as ordinary code.
    if n.kind == N_CLASS_MEMBER && member_is_field(n) {
        scan_all_names(set, n.b);
        if (n.flags & NF_COMPUTED) != 0 { scan_inner(set, n.a, false); }
        return;
    }
    scan_inner(set, n.a, false);
    scan_inner(set, n.b, false);
    scan_inner(set, n.c, false);
    scan_inner(set, n.d, false);
    for i32 i = 0; i < n.kids.len; i++ {
        scan_inner(set, *(n.kids.items + i), false);
    }
}

// --- binding declaration helpers ------------------------------------------------

// A binding for `name` in the innermost scope. Bindings are pushed as scopes
// open and truncated as they close, so everything at the current depth sits at
// the end of the list; `want_lexical` narrows the search to let/const/class.
private bool bound_here(FScope* fs, str name, bool want_lexical) {
    for i32 i = fs.binds.len - 1; i >= 0; i-- {
        CBind b = vec_get(&fs.binds, i);
        if b.depth < fs.depth { return false; }
        if str_equal(b.name, name) { return !want_lexical || b.tdz; }
    }
    return false;
}

private void redeclared(Compiler* co, Node* at, str name) {
    string m = format("'{}' has already been declared", name);
    cerror(co, at, m);
    free(m);
}

// The words strict-mode code keeps for itself.
private bool strict_reserved(str name) {
    return str_equal(name, "implements") || str_equal(name, "interface")
        || str_equal(name, "package") || str_equal(name, "private")
        || str_equal(name, "protected") || str_equal(name, "public")
        || str_equal(name, "static") || str_equal(name, "let") || str_equal(name, "yield");
}

// In strict-mode code nothing may be named eval or arguments, and the
// reserved words may not name anything.
private void check_strict_binding(Compiler* co, Node* at, str name) {
    if !co.strict { return; }
    if str_equal(name, "eval") || str_equal(name, "arguments") {
        cerror(co, at, "Unexpected eval or arguments in strict mode");
    } else if strict_reserved(name) {
        cerror(co, at, "Unexpected strict mode reserved word");
    }
}

private void declare_lexical(Compiler* co, Node* at, str name, bool is_const) {
    FScope* fs = co.cur;
    // a lexical name may not share its scope with any other declaration
    if at != null && bound_here(fs, name, false) { redeclared(co, at, name); }
    if at != null { check_strict_binding(co, at, name); }
    i32 bi = declare(co, name, is_const, true);
    CBind b = vec_get(&fs.binds, bi);
    if b.is_cell {
        ch_op_u16(&fs.ch, OP_NEWCELL_HOLE, b.slot);
    } else {
        ch_op_u16(&fs.ch, OP_SETHOLE, b.slot);
    }
}

private void declare_plain_const(Compiler* co, Node* at, str name, bool is_const) {
    FScope* fs = co.cur;
    // a function declaration may repeat, but not over a lexical name
    if at != null && bound_here(fs, name, true) { redeclared(co, at, name); }
    if at != null { check_strict_binding(co, at, name); }
    i32 bi = declare(co, name, is_const, false);
    CBind b = vec_get(&fs.binds, bi);
    if b.is_cell {
        ch_op_u16(&fs.ch, OP_NEWCELL_UNDEF, b.slot);
    }
}

private void declare_plain(Compiler* co, Node* at, str name) {
    declare_plain_const(co, at, name, false);
}

// Walks a binding pattern applying `mode` per name:
// 0 lexical let, 1 lexical const, 2 plain, 3 hoisted var,
// 4 plain and immutable (a `for (const x of ...)` head).
private void declare_pattern(Compiler* co, Node* pat, i32 mode) {
    if pat == null { return; }
    i32 k = pat.kind;
    if k == N_IDENT {
        if mode == 0 { declare_lexical(co, pat, pat.name, false); }
        if mode == 1 { declare_lexical(co, pat, pat.name, true); }
        if mode == 2 { declare_plain(co, pat, pat.name); }
        if mode == 3 { hoist_declare_var(co, pat); }
        if mode == 4 { declare_plain_const(co, pat, pat.name, true); }
        return;
    }
    if k == N_ASSIGN_PATTERN || k == N_REST {
        declare_pattern(co, pat.a, mode);
        return;
    }
    if k == N_ARRAY_PATTERN {
        for i32 i = 0; i < pat.kids.len; i++ {
            Node* e = *(pat.kids.items + i);
            if e.kind == N_HOLE { continue; }
            declare_pattern(co, e, mode);
        }
        return;
    }
    if k == N_OBJECT_PATTERN {
        for i32 i = 0; i < pat.kids.len; i++ {
            Node* pp = *(pat.kids.items + i);
            if pp.kind == N_REST {
                declare_pattern(co, pp.a, mode);
            } else {
                declare_pattern(co, pp.b, mode);
            }
        }
        return;
    }
    cerror(co, pat, "unsupported binding pattern");
}

// --- var hoisting ----------------------------------------------------------

private void hoist_declare_var(Compiler* co, Node* id) {
    FScope* fs = co.cur;
    check_strict_binding(co, id, id.name);
    i32 li = find_local(fs, id.name);
    if li >= 0 { return; }   // var redeclaration shares the binding
    i32 bi = declare(co, id.name, false, false);
    CBind b = vec_get(&fs.binds, bi);
    if b.is_cell {
        ch_op_u16(&fs.ch, OP_NEWCELL_UNDEF, b.slot);
    }
}

// The var-declared names of a statement list, used to reject a lexical name
// that collides with a `var` in the same scope. `var` hoists out of nested
// blocks but not out of functions, so the walk mirrors hoist_vars.
private void collect_var_names(Node* n, Vec<str>* out) {
    if n == null { return; }
    if n.kind == N_FUNCTION || n.kind == N_CLASS { return; }
    if n.kind == N_VAR && (n.flags & (NF_LET | NF_CONST)) == 0 {
        for i32 i = 0; i < n.kids.len; i++ {
            collect_pattern_names((*(n.kids.items + i)).a, out);
        }
        return;
    }
    collect_var_names(n.a, out);
    collect_var_names(n.b, out);
    collect_var_names(n.c, out);
    collect_var_names(n.d, out);
    for i32 i = 0; i < n.kids.len; i++ {
        collect_var_names(*(n.kids.items + i), out);
    }
}

private bool names_has(Vec<str>* names, str name) {
    for i32 i = 0; i < names.len; i++ {
        if str_equal(vec_get(names, i), name) { return true; }
    }
    return false;
}

// Reports each lexical name in `pat` that a `var` in the same scope also binds.
private void check_lexical_vs_var(Compiler* co, Node* pat, Vec<str>* vnames) {
    if vnames.len == 0 { return; }
    Vec<str> lnames = vec_new<str>(2);
    collect_pattern_names(pat, &lnames);
    for i32 i = 0; i < lnames.len; i++ {
        str nm = vec_get(&lnames, i);
        if names_has(vnames, nm) { redeclared(co, pat, nm); }
    }
    vec_free(&lnames);
}

private void hoist_vars(Compiler* co, Node* n) {
    if n == null { return; }
    if n.kind == N_FUNCTION || n.kind == N_CLASS { return; }
    if n.kind == N_VAR && (n.flags & (NF_LET | NF_CONST)) == 0 {
        for i32 i = 0; i < n.kids.len; i++ {
            Node* d = *(n.kids.items + i);
            declare_pattern(co, d.a, 3);
        }
        return;
    }
    hoist_vars(co, n.a);
    hoist_vars(co, n.b);
    hoist_vars(co, n.c);
    hoist_vars(co, n.d);
    for i32 i = 0; i < n.kids.len; i++ {
        hoist_vars(co, *(n.kids.items + i));
    }
}

// --- identifier load/store -----------------------------------------------------

private void emit_load_ident(Compiler* co, Node* n) {
    FScope* fs = co.cur;
    if co.strict && strict_reserved(n.name) {
        cerror(co, n, "Unexpected strict mode reserved word");
    }
    if co.in_static_block && str_equal(n.name, "await") {
        cerror(co, n, "Unexpected reserved word");
    }
    // `arguments` in an ordinary function is that function's OWN arguments
    // object, never a capture of an enclosing function's — so resolve it
    // before the local/upvalue walk, unless a real local/param shadows it.
    // Arrows fall through to the walk and capture the enclosing function's
    // `arguments` local as an upvalue (lexical, like `this`).
    if str_equal(n.name, "arguments") && !fs.is_arrow && fs.parent != null
       && find_local(fs, "arguments") < 0 {
        ch_op(&fs.ch, OP_ARGUMENTS);
        fs.needs_arguments = true;
        return;
    }
    i32 li = find_local(fs, n.name);
    if li >= 0 {
        CBind b = vec_get(&fs.binds, li);
        i32 op = OP_GETLOCAL;
        if b.is_cell {
            op = b.tdz ? OP_GETCELL_CHK : OP_GETCELL;
        } else if b.tdz {
            op = OP_GETLOCAL_CHK;
        }
        ch_op_u16(&fs.ch, op, b.slot);
        return;
    }
    i32 ui = resolve_upval(fs, n.name);
    if ui >= 0 {
        CUp u = vec_get(&fs.ups, ui);
        ch_op_u16(&fs.ch, u.tdz ? OP_GETUPVAL_CHK : OP_GETUPVAL, ui);
        return;
    }
    // live module import: read the dependency namespace property
    if co.in_module {
        ModImport* mi = strmap_get<ModImport>(&co.mod_imports, n.name);
        if mi != null {
            emit_load_name(co, mi.slot_name, n);
            ch_op_u16(&fs.ch, OP_GETIMPORT, name_const(co, mi.prop));
            ch_u16(&fs.ch, ch_add_const(&fs.ch, import_message(co, mi)));
            return;
        }
    }
    ch_op_u16(&fs.ch, OP_GETGLOBAL, name_const(co, n.name));
}

private void emit_load_name(Compiler* co, str name, Node* at) {
    Node tmp;
    tmp.kind = N_IDENT;
    tmp.name = name;
    if at != null { tmp.span = at.span; }
    emit_load_ident(co, &tmp);
}

// An exported binding lives in the module namespace as well: after a
// store, with the value still on the stack, copy it to every name the
// binding is exported under. Importers read the namespace, so this is
// what makes the export a live binding.
private void emit_export_writes(Compiler* co, str name, Node* at) {
    Chunk* ch = &co.cur.ch;
    i32* head = strmap_get<i32>(&co.export_heads, name);
    i32 i = head != null ? *head : -1;
    while i >= 0 {
        ExportName e = vec_get(&co.export_names, i);
        emit_load_name(co, co.ns_name, at);
        emit_load_name(co, name, at);
        ch_op_u16(ch, OP_SETPROP, name_const(co, e.exported));
        ch_op(ch, OP_POP);
        i = e.next;
    }
}

// Emits a store that keeps the value on the stack. A store to a const, to
// a class's own name or to an import is not an early error: the value is
// computed and the store throws, so the opcode stands in for the write.
private void emit_store_ident(Compiler* co, Node* n) {
    FScope* fs = co.cur;
    if co.strict && (str_equal(n.name, "eval") || str_equal(n.name, "arguments")) {
        cerror(co, n, "Unexpected eval or arguments in strict mode");
    }
    i32 li = find_local(fs, n.name);
    if li >= 0 {
        CBind b = vec_get(&fs.binds, li);
        if b.is_const {
            ch_op(&fs.ch, OP_SETCONST_ERR);
            return;
        }
        ch_op_u16(&fs.ch, b.is_cell ? OP_SETCELL : OP_SETLOCAL, b.slot);
        if b.exported { emit_export_writes(co, n.name, n); }
        return;
    }
    i32 ui = resolve_upval(fs, n.name);
    if ui >= 0 {
        CUp u = vec_get(&fs.ups, ui);
        if u.is_const {
            ch_op(&fs.ch, OP_SETCONST_ERR);
            return;
        }
        ch_op_u16(&fs.ch, OP_SETUPVAL, ui);
        if u.exported { emit_export_writes(co, n.name, n); }
        return;
    }
    if co.in_module && strmap_get<ModImport>(&co.mod_imports, n.name) != null {
        // an import is an immutable binding, refused when the store runs
        ch_op(&fs.ch, OP_SETCONST_ERR);
        return;
    }
    ch_op_u16(&fs.ch, OP_SETGLOBAL, name_const(co, n.name));
}

// Direct store for initialization; bypasses the const check.
private void emit_init_binding(Compiler* co, i32 bind_idx) {
    FScope* fs = co.cur;
    CBind b = vec_get(&fs.binds, bind_idx);
    ch_op_u16(&fs.ch, b.is_cell ? OP_SETCELL : OP_SETLOCAL, b.slot);
    if b.exported { emit_export_writes(co, b.name, null); }
    ch_op(&fs.ch, OP_POP);
}

// In a static member, and in an arrow inside one, `super.x` reads the parent
// class itself; everywhere else it reads the parent's prototype.
private bool super_home_is_static(Compiler* co) {
    if co.cur.static_home { return true; }
    return !co.cur.is_arrow && co.static_this;
}

// Loads the parent object a `super.x` reads from.
private void emit_super_home(Compiler* co, Node* at) {
    emit_load_name(co, "%super", at);
    if !super_home_is_static(co) {
        ch_op_u16(&co.cur.ch, OP_GETPROP, name_const(co, "prototype"));
    }
}

// `this`: the class-scoped binding inside a static block or field
// initializer, and in an arrow that closed over one; the frame's own
// otherwise.
private void emit_this(Compiler* co, Node* at) {
    FScope* fs = co.cur;
    str nm = "this";
    if fs.is_arrow {
        if find_local(fs, nm) >= 0 || resolve_upval(fs, nm) >= 0 {
            emit_load_name(co, nm, at);
            return;
        }
    } else if co.static_this && find_local(fs, nm) >= 0 {
        emit_load_name(co, nm, at);
        return;
    }
    ch_op(&fs.ch, OP_THIS);
}

private bool super_available(Compiler* co) {
    str nm = "%super";
    if find_local(co.cur, nm) >= 0 { return true; }
    return resolve_upval(co.cur, nm) >= 0;
}

// super() belongs to the constructor of a derived class, and to the arrows
// inside it.
private bool super_call_ok(Compiler* co) {
    FScope* fs = co.cur;
    while fs != null && fs.is_arrow { fs = fs.parent; }
    return fs != null && fs.super_call_ok;
}

// --- destructuring ---------------------------------------------------------------

// An assignment target that is a property reference. The language
// evaluates the reference before it fetches the value it will hold, so
// its object and key go into slots first.
private bool target_is_ref(Node* t) {
    return t != null && (t.kind == N_MEMBER || t.kind == N_INDEX) && (t.flags & NF_OPT_CHAIN) == 0;
}

private void emit_ref_prepare(Compiler* co, Node* t, i32* t_obj, i32* t_key) {
    Chunk* ch = &co.cur.ch;
    *t_obj = alloc_slot(co.cur);
    compile_expr(co, t.a);
    ch_op_u16(ch, OP_SETLOCAL, *t_obj);
    ch_op(ch, OP_POP);
    *t_key = -1;
    if t.kind == N_INDEX {
        *t_key = alloc_slot(co.cur);
        compile_expr(co, t.b);
        ch_op_u16(ch, OP_SETLOCAL, *t_key);
        ch_op(ch, OP_POP);
    }
}

// [value] -> []: stores through a prepared reference, then frees its slots
private void emit_ref_store(Compiler* co, Node* t, i32 t_obj, i32 t_key) {
    Chunk* ch = &co.cur.ch;
    i32 t_val = alloc_slot(co.cur);
    ch_op_u16(ch, OP_SETLOCAL, t_val);
    ch_op(ch, OP_POP);
    ch_op_u16(ch, OP_GETLOCAL, t_obj);
    if t.kind == N_INDEX {
        ch_op_u16(ch, OP_GETLOCAL, t_key);
        ch_op_u16(ch, OP_GETLOCAL, t_val);
        ch_op(ch, OP_SETINDEX);
    } else {
        ch_op_u16(ch, OP_GETLOCAL, t_val);
        if (t.flags & NF_PRIVATE) != 0 {
            ch_op_u16(ch, OP_SETPRIVATE, private_key_const(co, t, t.name));
        } else {
            ch_op_u16(ch, OP_SETPROP, name_const(co, t.name));
        }
    }
    ch_op(ch, OP_POP);
    co.cur.cur_slots -= (t_key >= 0 ? 3 : 2);
}

// [value] -> [value]: an undefined value takes the default
private void emit_default_value(Compiler* co, Node* dflt) {
    Chunk* ch = &co.cur.ch;
    ch_op(ch, OP_DUP);
    ch_op(ch, OP_UNDEF);
    ch_op(ch, OP_SEQ);
    i32 j = ch_jump(ch, OP_JUMPF);
    ch_op(ch, OP_POP);
    compile_expr(co, dflt);
    ch_patch(ch, j);
}

// The target and default of an assignment element, which may carry the
// default as an assignment expression (the cover grammar).
private void split_assign_element(Node* e, Node** tgt, Node** dflt) {
    *tgt = e;
    *dflt = null;
    if e != null && (e.kind == N_ASSIGN_PATTERN || (e.kind == N_ASSIGN && e.op == TOK_EQ)) {
        *tgt = e.a;
        *dflt = e.b;
    }
}

// Consumes the value on top of the stack, storing per pattern leaf.
// declare_mode initializes bindings; otherwise leaves are assignment
// targets (ident, member, index).
private void compile_destructure(Compiler* co, Node* pat, bool declare_mode) {
    Chunk* ch = &co.cur.ch;
    i32 k = pat.kind;
    if k == N_IDENT {
        if declare_mode {
            i32 li = find_local(co.cur, pat.name);
            if li < 0 {
                cerror(co, pat, "unresolved binding");
                ch_op(ch, OP_POP);
                return;
            }
            emit_init_binding(co, li);
        } else {
            emit_store_ident(co, pat);
            ch_op(ch, OP_POP);
        }
        return;
    }
    if !declare_mode && (k == N_MEMBER || k == N_INDEX) {
        if k == N_MEMBER && (pat.flags & NF_OPT_CHAIN) != 0 {
            cerror(co, pat, "invalid assignment target");
            ch_op(ch, OP_POP);
            return;
        }
        i32 tmp = alloc_slot(co.cur);
        ch_op_u16(ch, OP_SETLOCAL, tmp);
        ch_op(ch, OP_POP);
        compile_expr(co, pat.a);
        if k == N_MEMBER {
            ch_op_u16(ch, OP_GETLOCAL, tmp);
            if (pat.flags & NF_PRIVATE) != 0 {
                ch_op_u16(ch, OP_SETPRIVATE, private_key_const(co, pat, pat.name));
            } else {
                ch_op_u16(ch, OP_SETPROP, name_const(co, pat.name));
            }
        } else {
            compile_expr(co, pat.b);
            ch_op_u16(ch, OP_GETLOCAL, tmp);
            ch_op(ch, OP_SETINDEX);
        }
        ch_op(ch, OP_POP);
        co.cur.cur_slots--;
        return;
    }
    if k == N_ASSIGN_PATTERN || (!declare_mode && k == N_ASSIGN && pat.op == TOK_EQ) {
        ch_op(ch, OP_DUP);
        ch_op(ch, OP_UNDEF);
        ch_op(ch, OP_SEQ);
        i32 j = ch_jump(ch, OP_JUMPF);
        ch_op(ch, OP_POP);
        // named evaluation: an anonymous default takes the bound name
        if pat.a != null && pat.a.kind == N_IDENT { infer_name(pat.b, pat.a.name); }
        compile_expr(co, pat.b);
        ch_patch(ch, j);
        compile_destructure(co, pat.a, declare_mode);
        return;
    }
    if k == N_ARRAY_PATTERN || (!declare_mode && k == N_ARRAY) {
        // Array patterns consume the value through the iterator protocol, so
        // any iterable works and errors from the iterator surface. `t_done`
        // tracks exhaustion, which decides both the value an element sees and
        // whether the iterator still has to be closed at the end.
        i32 t_iter = alloc_slot(co.cur);
        i32 t_done = alloc_slot(co.cur);
        ch_op(ch, OP_GET_ITER);
        ch_op_u16(ch, OP_SETLOCAL, t_iter);
        ch_op(ch, OP_POP);
        ch_op(ch, OP_FALSE);
        ch_op_u16(ch, OP_SETLOCAL, t_done);
        ch_op(ch, OP_POP);
        // an element that throws, or a resume that returns into a pattern
        // suspended on a yield, still releases the iterator
        i32 jclose = ch_jump(ch, OP_TRY_PUSH);
        bool exhausted = false;
        for i32 i = 0; i < pat.kids.len; i++ {
            Node* e = *(pat.kids.items + i);
            if e.kind == N_HOLE {
                // an elision still advances the iterator
                ch_op_u16(ch, OP_GETLOCAL, t_iter);
                ch_op_u16(ch, OP_ITER_STEP, t_done);
                ch_op(ch, OP_POP);
                continue;
            }
            if e.kind == N_REST || e.kind == N_SPREAD {
                // in the assignment form the pattern arrived as an array
                // literal, so the rest rules are checked here: last, with
                // no trailing comma, and with no default
                if i != pat.kids.len - 1 || (pat.flags & NF_REST) != 0 {
                    cerror(co, e, "Rest element must be last element");
                }
                if !declare_mode && e.a != null && e.a.kind == N_ASSIGN && e.a.op == TOK_EQ {
                    cerror(co, e, "Rest element may not have a default initializer");
                }
                if !declare_mode && target_is_ref(e.a) {
                    i32 r_obj = 0;
                    i32 r_key = 0;
                    emit_ref_prepare(co, e.a, &r_obj, &r_key);
                    ch_op_u16(ch, OP_GETLOCAL, t_iter);
                    ch_op_u16(ch, OP_ITER_REST, t_done);
                    emit_ref_store(co, e.a, r_obj, r_key);
                } else {
                    ch_op_u16(ch, OP_GETLOCAL, t_iter);
                    ch_op_u16(ch, OP_ITER_REST, t_done);
                    compile_destructure(co, e.a, declare_mode);
                }
                exhausted = true;
                break;
            }
            Node* tgt = null;
            Node* dflt = null;
            split_assign_element(e, &tgt, &dflt);
            if !declare_mode && target_is_ref(tgt) {
                i32 r_obj = 0;
                i32 r_key = 0;
                emit_ref_prepare(co, tgt, &r_obj, &r_key);
                ch_op_u16(ch, OP_GETLOCAL, t_iter);
                ch_op_u16(ch, OP_ITER_STEP, t_done);
                if dflt != null { emit_default_value(co, dflt); }
                emit_ref_store(co, tgt, r_obj, r_key);
                continue;
            }
            ch_op_u16(ch, OP_GETLOCAL, t_iter);
            ch_op_u16(ch, OP_ITER_STEP, t_done);
            compile_destructure(co, e, declare_mode);
        }
        ch_op(ch, OP_TRY_POP);
        // a pattern that stopped early releases the iterator
        if !exhausted {
            ch_op_u16(ch, OP_GETLOCAL, t_iter);
            ch_op_u16(ch, OP_ITER_CLOSE, t_done);
        }
        i32 jend = ch_jump(ch, OP_JUMP);
        ch_patch(ch, jclose);
        // the completion's value is on the stack; close, then let it carry on
        ch_op_u16(ch, OP_GETLOCAL, t_iter);
        ch_op_u16(ch, OP_ITER_CLOSE_ABRUPT, t_done);
        ch_op(ch, OP_RETHROW);
        ch_patch(ch, jend);
        co.cur.cur_slots -= 2;
        return;
    }
    if k == N_OBJECT_PATTERN || (!declare_mode && k == N_OBJECT) {
        // null and undefined cannot be destructured, even by an empty pattern
        ch_op(ch, OP_REQUIRE_OBJ);
        i32 tmp = alloc_slot(co.cur);
        ch_op_u16(ch, OP_SETLOCAL, tmp);
        ch_op(ch, OP_POP);
        Vec<i32> taken = vec_new<i32>(4);
        for i32 i = 0; i < pat.kids.len; i++ {
            Node* pp = *(pat.kids.items + i);
            if pp.kind == N_REST || pp.kind == N_SPREAD {
                if i != pat.kids.len - 1 {
                    cerror(co, pp, "a rest property must be last");
                }
                // rest object: copy remaining own props
                JsObject* ex = js_new_array(co.heap, null);
                gc_root(co.heap, value_cell(&ex.head));
                for i32 j = 0; j < taken.len; j++ {
                    js_array_set(ex, j, value_int(vec_get(&taken, j)));
                }
                i32 ci = ch_add_const(ch, value_cell(&ex.head));
                ch_op_u16(ch, OP_GETLOCAL, tmp);
                ch_op_u16(ch, OP_OBJ_REST, ci);
                compile_destructure(co, pp.a, declare_mode);
                continue;
            }
            Node* keyn = pp.a;
            Node* target = pp.b;
            if declare_mode == false && (pp.flags & NF_SHORTHAND) != 0 {
                // cover grammar: {x} or {x = default}
                target = pp.a;
                if pp.b != null {
                    // default via synthetic assign-pattern shape
                    ch_op_u16(ch, OP_GETLOCAL, tmp);
                    ch_op_u16(ch, OP_GETPROP, prop_key_const(co, keyn));
                    ch_op(ch, OP_DUP);
                    ch_op(ch, OP_UNDEF);
                    ch_op(ch, OP_SEQ);
                    i32 j2 = ch_jump(ch, OP_JUMPF);
                    ch_op(ch, OP_POP);
                    // named evaluation: an anonymous default takes the name
                    if target != null && target.kind == N_IDENT { infer_name(pp.b, target.name); }
                    compile_expr(co, pp.b);
                    ch_patch(ch, j2);
                    compile_destructure(co, target, declare_mode);
                    u32 a2 = atom_intern(co.atoms, keyn.name);
                    vec_push(&taken, cast(i32, a2));
                    continue;
                }
            }
            Node* tgt = null;
            Node* dflt = null;
            split_assign_element(target, &tgt, &dflt);
            bool by_ref = !declare_mode && target_is_ref(tgt);
            i32 t_k = -1;
            if (pp.flags & NF_COMPUTED) != 0 {
                // the key is evaluated first, then a reference target
                t_k = alloc_slot(co.cur);
                compile_expr(co, keyn);
                ch_op_u16(ch, OP_SETLOCAL, t_k);
                ch_op(ch, OP_POP);
            }
            i32 r_obj = 0;
            i32 r_key = 0;
            if by_ref { emit_ref_prepare(co, tgt, &r_obj, &r_key); }
            if t_k >= 0 {
                ch_op_u16(ch, OP_GETLOCAL, tmp);
                ch_op_u16(ch, OP_GETLOCAL, t_k);
                ch_op(ch, OP_GETINDEX);
            } else {
                ch_op_u16(ch, OP_GETLOCAL, tmp);
                ch_op_u16(ch, OP_GETPROP, prop_key_const(co, keyn));
                if keyn.kind != N_NUMBER {
                    u32 a2 = atom_intern(co.atoms, keyn.name);
                    vec_push(&taken, cast(i32, a2));
                }
            }
            if by_ref {
                if dflt != null { emit_default_value(co, dflt); }
                emit_ref_store(co, tgt, r_obj, r_key);
            } else {
                compile_destructure(co, target, declare_mode);
            }
            if t_k >= 0 { co.cur.cur_slots--; }
        }
        vec_free(&taken);
        co.cur.cur_slots--;
        return;
    }
    cerror(co, pat, "unsupported destructuring target");
    ch_op(ch, OP_POP);
}

// --- expressions ------------------------------------------------------------------

private i32 bin_op_code(i32 tok) {
    if tok == TOK_PLUS { return OP_ADD; }
    if tok == TOK_MINUS { return OP_SUB; }
    if tok == TOK_STAR { return OP_MUL; }
    if tok == TOK_SLASH { return OP_DIV; }
    if tok == TOK_PERCENT { return OP_MOD; }
    if tok == TOK_STARSTAR { return OP_POW; }
    if tok == TOK_EQEQ { return OP_EQ; }
    if tok == TOK_NEQ { return OP_NEQ; }
    if tok == TOK_EQEQEQ { return OP_SEQ; }
    if tok == TOK_NEQEQEQ { return OP_SNEQ; }
    if tok == TOK_LT { return OP_LT; }
    if tok == TOK_GT { return OP_GT; }
    if tok == TOK_LE { return OP_LE; }
    if tok == TOK_GE { return OP_GE; }
    if tok == TOK_AMP { return OP_BAND; }
    if tok == TOK_PIPE { return OP_BOR; }
    if tok == TOK_CARET { return OP_BXOR; }
    if tok == TOK_LSHIFT { return OP_SHL; }
    if tok == TOK_RSHIFT { return OP_SHR; }
    if tok == TOK_URSHIFT { return OP_USHR; }
    if tok == TOK_KW_INSTANCEOF { return OP_INSTANCEOF; }
    if tok == TOK_KW_IN { return OP_IN; }
    return -1;
}

private i32 compound_op_code(i32 tok) {
    if tok == TOK_PLUS_EQ { return OP_ADD; }
    if tok == TOK_MINUS_EQ { return OP_SUB; }
    if tok == TOK_STAR_EQ { return OP_MUL; }
    if tok == TOK_SLASH_EQ { return OP_DIV; }
    if tok == TOK_PERCENT_EQ { return OP_MOD; }
    if tok == TOK_STARSTAR_EQ { return OP_POW; }
    if tok == TOK_LSHIFT_EQ { return OP_SHL; }
    if tok == TOK_RSHIFT_EQ { return OP_SHR; }
    if tok == TOK_URSHIFT_EQ { return OP_USHR; }
    if tok == TOK_AMP_EQ { return OP_BAND; }
    if tok == TOK_PIPE_EQ { return OP_BOR; }
    if tok == TOK_CARET_EQ { return OP_BXOR; }
    return -1;
}

// Pushes plain args and returns argc, or builds an args array for
// spread calls and returns -1.
private i32 compile_args(Compiler* co, NodeList* kids) {
    Chunk* ch = &co.cur.ch;
    bool has_spread = false;
    for i32 i = 0; i < kids.len; i++ {
        if (*(kids.items + i)).kind == N_SPREAD { has_spread = true; }
    }
    if !has_spread {
        for i32 i = 0; i < kids.len; i++ {
            compile_expr(co, *(kids.items + i));
        }
        return kids.len;
    }
    ch_op_u16(ch, OP_NEWARR, 0);
    for i32 i = 0; i < kids.len; i++ {
        Node* arg = *(kids.items + i);
        if arg.kind == N_SPREAD {
            compile_expr(co, arg.a);
            ch_op(ch, OP_ARR_SPREAD);
        } else {
            compile_expr(co, arg);
            ch_op(ch, OP_ARR_APPEND);
        }
    }
    return -1;
}

private void compile_assign(Compiler* co, Node* n) {
    Chunk* ch = &co.cur.ch;
    Node* t = n.a;
    if n.op == TOK_EQ {
        if t.kind == N_IDENT {
            // named evaluation: `x = function(){}` names the function `x`
            infer_name(n.b, t.name);
            compile_expr(co, n.b);
            emit_store_ident(co, t);
            return;
        }
        if t.kind == N_MEMBER {
            if (t.flags & NF_OPT_CHAIN) != 0 {
                cerror(co, t, "invalid assignment target");
                return;
            }
            compile_expr(co, t.a);
            compile_expr(co, n.b);
            if (t.flags & NF_PRIVATE) != 0 {
                ch_op_u16(ch, OP_SETPRIVATE, private_key_const(co, t, t.name));
            } else {
                ch_op_u16(ch, OP_SETPROP, name_const(co, t.name));
            }
            return;
        }
        if t.kind == N_INDEX {
            compile_expr(co, t.a);
            compile_expr(co, t.b);
            compile_expr(co, n.b);
            ch_op(ch, OP_SETINDEX);
            return;
        }
        if t.kind == N_ARRAY || t.kind == N_OBJECT {
            compile_expr(co, n.b);
            ch_op(ch, OP_DUP);
            compile_destructure(co, t, false);
            return;
        }
        cerror(co, t, "invalid assignment target");
        return;
    }
    if n.op == TOK_AMPAMP_EQ || n.op == TOK_PIPEPIPE_EQ || n.op == TOK_QUESTION_QUESTION_EQ {
        // Short-circuiting assignment: the store only happens on the branch
        // that takes it, so a setter is left alone otherwise. The target's
        // subexpressions are evaluated once, hence the temporaries.
        i32 jop = OP_JF_KEEP;
        if n.op == TOK_PIPEPIPE_EQ { jop = OP_JT_KEEP; }
        if n.op == TOK_QUESTION_QUESTION_EQ { jop = OP_JNN_KEEP; }
        if t.kind == N_IDENT {
            // named evaluation applies to an identifier target, not a member
            infer_name(n.b, t.name);
            emit_load_ident(co, t);
            i32 j = ch_jump(ch, jop);
            compile_expr(co, n.b);
            emit_store_ident(co, t);
            ch_patch(ch, j);
            return;
        }
        if t.kind == N_MEMBER {
            if (t.flags & NF_OPT_CHAIN) != 0 {
                cerror(co, t, "invalid assignment target");
                return;
            }
            bool priv = (t.flags & NF_PRIVATE) != 0;
            i32 kc = priv ? private_key_const(co, t, t.name) : name_const(co, t.name);
            i32 t_obj = alloc_slot(co.cur);
            compile_expr(co, t.a);
            ch_op_u16(ch, OP_SETLOCAL, t_obj);
            ch_op(ch, OP_POP);
            ch_op_u16(ch, OP_GETLOCAL, t_obj);
            ch_op_u16(ch, priv ? OP_GETPRIVATE : OP_GETPROP, kc);
            i32 j = ch_jump(ch, jop);
            ch_op_u16(ch, OP_GETLOCAL, t_obj);
            compile_expr(co, n.b);
            ch_op_u16(ch, priv ? OP_SETPRIVATE : OP_SETPROP, kc);
            ch_patch(ch, j);
            co.cur.cur_slots--;
            return;
        }
        if t.kind == N_INDEX {
            if (t.flags & NF_OPT_CHAIN) != 0 {
                cerror(co, t, "invalid assignment target");
                return;
            }
            i32 t_obj = alloc_slot(co.cur);
            i32 t_key = alloc_slot(co.cur);
            compile_expr(co, t.a);
            ch_op_u16(ch, OP_SETLOCAL, t_obj);
            ch_op(ch, OP_POP);
            compile_expr(co, t.b);
            ch_op_u16(ch, OP_SETLOCAL, t_key);
            ch_op(ch, OP_POP);
            ch_op_u16(ch, OP_GETLOCAL, t_obj);
            ch_op_u16(ch, OP_GETLOCAL, t_key);
            ch_op(ch, OP_GETINDEX);
            i32 j = ch_jump(ch, jop);
            ch_op_u16(ch, OP_GETLOCAL, t_obj);
            ch_op_u16(ch, OP_GETLOCAL, t_key);
            compile_expr(co, n.b);
            ch_op(ch, OP_SETINDEX);
            ch_patch(ch, j);
            co.cur.cur_slots -= 2;
            return;
        }
        cerror(co, t, "invalid assignment target");
        return;
    }
    i32 op = compound_op_code(n.op);
    if op < 0 {
        cerror(co, n, "unsupported assignment operator");
        return;
    }
    if t.kind == N_IDENT {
        emit_load_ident(co, t);
        compile_expr(co, n.b);
        ch_op(ch, op);
        emit_store_ident(co, t);
        return;
    }
    if t.kind == N_MEMBER {
        bool priv = (t.flags & NF_PRIVATE) != 0;
        i32 kc = priv ? private_key_const(co, t, t.name) : name_const(co, t.name);
        compile_expr(co, t.a);
        ch_op(ch, OP_DUP);
        ch_op_u16(ch, priv ? OP_GETPRIVATE : OP_GETPROP, kc);
        compile_expr(co, n.b);
        ch_op(ch, op);
        ch_op_u16(ch, priv ? OP_SETPRIVATE : OP_SETPROP, kc);
        return;
    }
    if t.kind == N_INDEX {
        compile_expr(co, t.a);
        compile_expr(co, t.b);
        ch_op(ch, OP_DUP2);
        ch_op(ch, OP_GETINDEX);
        compile_expr(co, n.b);
        ch_op(ch, op);
        ch_op(ch, OP_SETINDEX);
        return;
    }
    cerror(co, t, "invalid assignment target");
}

private void compile_update(Compiler* co, Node* n) {
    Chunk* ch = &co.cur.ch;
    Node* t = n.a;
    i32 step = n.op == TOK_PLUSPLUS ? OP_INC : OP_DEC;
    bool prefix = (n.flags & NF_PREFIX) != 0;
    if t.kind == N_IDENT {
        emit_load_ident(co, t);
        ch_op(ch, OP_TONUM);
        if !prefix { ch_op(ch, OP_DUP); }
        ch_op(ch, step);
        emit_store_ident(co, t);
        if !prefix { ch_op(ch, OP_POP); }
        return;
    }
    if t.kind == N_MEMBER || t.kind == N_INDEX {
        i32 tmp = alloc_slot(co.cur);
        i32 mkc = 0;
        bool mpriv = t.kind == N_MEMBER && (t.flags & NF_PRIVATE) != 0;
        if t.kind == N_MEMBER {
            mkc = mpriv ? private_key_const(co, t, t.name) : name_const(co, t.name);
            compile_expr(co, t.a);
            ch_op(ch, OP_DUP);
            ch_op_u16(ch, mpriv ? OP_GETPRIVATE : OP_GETPROP, mkc);
        } else {
            compile_expr(co, t.a);
            compile_expr(co, t.b);
            ch_op(ch, OP_DUP2);
            ch_op(ch, OP_GETINDEX);
        }
        ch_op(ch, OP_TONUM);
        ch_op_u16(ch, OP_SETLOCAL, tmp);
        ch_op(ch, step);
        if t.kind == N_MEMBER {
            ch_op_u16(ch, mpriv ? OP_SETPRIVATE : OP_SETPROP, mkc);
        } else {
            ch_op(ch, OP_SETINDEX);
        }
        if !prefix {
            ch_op(ch, OP_POP);
            ch_op_u16(ch, OP_GETLOCAL, tmp);
        }
        co.cur.cur_slots--;
        return;
    }
    cerror(co, t, "invalid update target");
}

private bool chain_has_opt(Node* n) {
    while n != null && (n.kind == N_MEMBER || n.kind == N_INDEX || n.kind == N_CALL) {
        if (n.flags & NF_OPT_CHAIN) != 0 { return true; }
        // a parenthesised sub-expression is the end of the chain, so an
        // optional link inside it does not make this access optional
        if n.a != null && (n.a.flags & NF_PARENED) != 0 { return false; }
        if n.kind == N_CALL && n.a != null
            && (n.a.kind == N_MEMBER || n.a.kind == N_INDEX)
            && (n.a.flags & NF_OPT_CHAIN) != 0 {
            return true;
        }
        n = n.a;
    }
    return false;
}

// The object part of a chain link. A parenthesised sub-expression is a
// complete chain of its own, so it is compiled separately and gets its own nil
// exit instead of sharing the enclosing one.
private void emit_chain_base(Compiler* co, Node* n, Vec<i32>* nils) {
    if (n.flags & NF_PARENED) != 0 { compile_expr(co, n); return; }
    emit_chain(co, n, nils);
}

private void emit_chain(Compiler* co, Node* n, Vec<i32>* nils) {
    Chunk* ch = &co.cur.ch;
    i32 k = n.kind;
    if k == N_MEMBER && n.a.kind != N_SUPER {
        emit_chain_base(co, n.a, nils);
        if (n.flags & NF_OPT_CHAIN) != 0 {
            vec_push(nils, ch_jump(ch, OP_JUMP_NULLISH));
        }
        if (n.flags & NF_PRIVATE) != 0 {
            ch_op_u16(ch, OP_GETPRIVATE, private_key_const(co, n, n.name));
        } else {
            ch_op_u16(ch, OP_GETPROP, name_const(co, n.name));
        }
        return;
    }
    if k == N_INDEX {
        emit_chain_base(co, n.a, nils);
        if (n.flags & NF_OPT_CHAIN) != 0 {
            vec_push(nils, ch_jump(ch, OP_JUMP_NULLISH));
        }
        compile_expr(co, n.b);
        ch_op(ch, OP_GETINDEX);
        return;
    }
    if k == N_CALL {
        Node* callee = n.a;
        if callee.kind == N_MEMBER && callee.a.kind != N_SUPER {
            emit_chain_base(co, callee.a, nils);
            if (callee.flags & NF_OPT_CHAIN) != 0 {
                vec_push(nils, ch_jump(ch, OP_JUMP_NULLISH));
            }
            if (callee.flags & NF_PRIVATE) != 0 {
                ch_op_u16(ch, OP_GETMETHOD_PRIV, private_key_const(co, callee, callee.name));
            } else {
                ch_op_u16(ch, OP_GETMETHOD, name_const(co, callee.name));
            }
        } else if callee.kind == N_INDEX {
            emit_chain_base(co, callee.a, nils);
            if (callee.flags & NF_OPT_CHAIN) != 0 {
                vec_push(nils, ch_jump(ch, OP_JUMP_NULLISH));
            }
            compile_expr(co, callee.b);
            ch_op(ch, OP_GETMETHOD_DYN);
        } else {
            emit_chain_base(co, callee, nils);
            if (n.flags & NF_OPT_CHAIN) != 0 {
                vec_push(nils, ch_jump(ch, OP_JUMP_NULLISH));
            }
            ch_op(ch, OP_UNDEF);
            i32 c = compile_args(co, &n.kids);
            if c >= 0 { ch_op_u16(ch, OP_CALL, c); } else { ch_op(ch, OP_CALL_ARRAY); }
            return;
        }
        if (n.flags & NF_OPT_CHAIN) != 0 {
            vec_push(nils, ch_jump(ch, OP_JUMP_NULLISH_METH));
        }
        i32 c = compile_args(co, &n.kids);
        if c >= 0 { ch_op_u16(ch, OP_CALL, c); } else { ch_op(ch, OP_CALL_ARRAY); }
        return;
    }
    compile_expr(co, n);
}

private void compile_opt_chain(Compiler* co, Node* n) {
    Chunk* ch = &co.cur.ch;
    Vec<i32> nils = vec_new<i32>(4);
    emit_chain(co, n, &nils);
    i32 jend = ch_jump(ch, OP_JUMP);
    while nils.len > 0 {
        ch_patch(ch, vec_pop(&nils));
    }
    ch_op(ch, OP_UNDEF);
    ch_patch(ch, jend);
    vec_free(&nils);
}

// `delete a?.b.c` deletes through the chain like an ordinary delete, except
// that a nullish link abandons the whole thing and reports success -- there
// was nothing to remove. Only the last link is a delete; everything before it
// is an ordinary read, which is what emit_chain already produces.
private void compile_delete_opt(Compiler* co, Node* t) {
    Chunk* ch = &co.cur.ch;
    Vec<i32> nils = vec_new<i32>(4);
    emit_chain_base(co, t.a, &nils);
    if (t.flags & NF_OPT_CHAIN) != 0 {
        vec_push(&nils, ch_jump(ch, OP_JUMP_NULLISH));
    }
    if t.kind == N_MEMBER {
        ch_op_u16(ch, OP_DELPROP, name_const(co, t.name));
    } else {
        compile_expr(co, t.b);
        ch_op(ch, OP_DELINDEX);
    }
    i32 jend = ch_jump(ch, OP_JUMP);
    while nils.len > 0 {
        ch_patch(ch, vec_pop(&nils));
    }
    ch_op(ch, OP_TRUE);
    ch_patch(ch, jend);
    vec_free(&nils);
}

private void compile_call(Compiler* co, Node* n) {
    Chunk* ch = &co.cur.ch;
    Node* callee = n.a;
    if callee.kind == N_IMPORT_EXPR {
        // dynamic import(spec): compile the specifier, then hand it and this
        // module's path to the runtime loader (OP_DYNIMPORT -> a promise).
        // a specifier, and at most an attributes object, which is accepted
        // and ignored; anything more is a syntax error
        if n.kids.len < 1 || n.kids.len > 2 {
            cerror(co, n, "import() takes a specifier and at most an options argument");
            ch_op(ch, OP_UNDEF);
            return;
        }
        compile_expr(co, *(n.kids.items + 0));
        ch_op_u16(ch, OP_CONST, str_const(co, co.src_name));
        ch_op(ch, OP_DYNIMPORT);
        return;
    }
    if callee.kind == N_SUPER {
        if !super_available(co) || !super_call_ok(co) {
            cerror(co, n, "'super' keyword unexpected here");
            ch_op(ch, OP_UNDEF);
            return;
        }
        emit_load_name(co, "%super", n);
        ch_op(ch, OP_THIS);
        i32 c = compile_args(co, &n.kids);
        // both super forms forward new.target to the base constructor
        if c >= 0 { ch_op_u16(ch, OP_SUPERCALL, c); } else { ch_op(ch, OP_SUPERCALL_ARRAY); }
        return;
    }
    if (callee.kind == N_MEMBER || callee.kind == N_INDEX) && callee.a.kind == N_SUPER {
        if !super_available(co) {
            cerror(co, n, "super outside a class method");
            ch_op(ch, OP_UNDEF);
            return;
        }
        emit_super_home(co, n);
        if callee.kind == N_INDEX {
            compile_expr(co, callee.b);
            ch_op(ch, OP_GETINDEX);
        } else {
            ch_op_u16(ch, OP_GETPROP, name_const(co, callee.name));
        }
        // the receiver stays `this`, as for super.name(...)
        emit_this(co, n);
        i32 c = compile_args(co, &n.kids);
        if c >= 0 { ch_op_u16(ch, OP_CALL, c); } else { ch_op(ch, OP_CALL_ARRAY); }
        return;
    }
    if chain_has_opt(n) {
        compile_opt_chain(co, n);
        return;
    }
    if callee.kind == N_MEMBER {
        compile_expr(co, callee.a);
        if (callee.flags & NF_PRIVATE) != 0 {
            ch_op_u16(ch, OP_GETMETHOD_PRIV, private_key_const(co, callee, callee.name));
        } else {
            ch_op_u16(ch, OP_GETMETHOD, name_const(co, callee.name));
        }
    } else if callee.kind == N_INDEX {
        compile_expr(co, callee.a);
        compile_expr(co, callee.b);
        ch_op(ch, OP_GETMETHOD_DYN);
    } else {
        compile_expr(co, callee);
        ch_op(ch, OP_UNDEF);
    }
    i32 c = compile_args(co, &n.kids);
    if c >= 0 { ch_op_u16(ch, OP_CALL, c); } else { ch_op(ch, OP_CALL_ARRAY); }
}

private void compile_expr(Compiler* co, Node* n) {
    Chunk* ch = &co.cur.ch;
    i32 k = n.kind;
    if k == N_NUMBER {
        ch_op_u16(ch, OP_CONST, ch_add_const(ch, num_value(n.num)));
        return;
    }
    if k == N_BIGINT {
        // literal text includes the trailing 'n'
        str t = n.name;
        if t.len > 0 && *(t.data + t.len - 1) == 'n' { t.len--; }
        // numeric separators are part of the literal but not of its value
        bool has_sep = false;
        for i32 i = 0; i < t.len; i++ {
            if *(t.data + i) == '_' { has_sep = true; }
        }
        if has_sep {
            u8* clean = cast(u8*, bump_alloc(co.arena, t.len));
            i32 w = 0;
            for i32 i = 0; i < t.len; i++ {
                u8 c = *(t.data + i);
                if c != '_' { *(clean + w) = c; w++; }
            }
            t.data = clean;
            t.len = w;
        }
        bool ok;
        BigNum bn = bn_from_str(t, &ok);
        if !ok { cerror(co, n, "invalid BigInt literal"); }
        GcBigInt* g = js_new_bigint(co.heap, bn);
        bn_free(&bn);
        Value bv = value_cell(&g.head);
        gc_root(co.heap, bv);   // stays rooted until the VM owns the template
        ch_op_u16(ch, OP_CONST, ch_add_const(ch, bv));
        return;
    }
    if k == N_STRING {
        ch_op_u16(ch, OP_CONST, str_const(co, n.name));
        return;
    }
    if k == N_BOOL {
        ch_op(ch, str_equal(n.name, "true") ? OP_TRUE : OP_FALSE);
        return;
    }
    if k == N_NULL { ch_op(ch, OP_NULL); return; }
    if k == N_REGEX {
        // an invalid literal is a syntax error of the program, not of the
        // statement that first evaluates it
        if !regex_flags_valid(n.aux) {
            cerror(co, n, "invalid regular expression flags");
        } else {
            RegexProg* probe = regex_compile(n.name, n.aux);
            if probe == null { cerror(co, n, "invalid regular expression"); }
            else { regex_free(probe); }
        }
        i32 src = str_const(co, n.name);
        i32 flags = str_const(co, n.aux);
        ch_op(ch, OP_REGEX);
        ch_u16(ch, src);
        ch_u16(ch, flags);
        return;
    }
    if k == N_IDENT { emit_load_ident(co, n); return; }
    if k == N_IMPORT_META {
        // import.meta: `url` as a file:// URL, plus the filename and dirname
        // node exposes, which is what an ESM file uses to reach a sibling.
        ch_op(ch, OP_NEWOBJ);
        ch_op(ch, OP_DUP);
        ch_op_u16(ch, OP_CONST, import_meta_url_const(co));
        ch_op_u16(ch, OP_SETPROP, name_const(co, "url"));
        ch_op(ch, OP_POP);
        ch_op(ch, OP_DUP);
        ch_op_u16(ch, OP_CONST, import_meta_path_const(co, false));
        ch_op_u16(ch, OP_SETPROP, name_const(co, "filename"));
        ch_op(ch, OP_POP);
        ch_op(ch, OP_DUP);
        ch_op_u16(ch, OP_CONST, import_meta_path_const(co, true));
        ch_op_u16(ch, OP_SETPROP, name_const(co, "dirname"));
        ch_op(ch, OP_POP);
        return;
    }
    if k == N_IMPORT_EXPR {
        cerror(co, n, "import is only valid as import(...) or import.meta");
        ch_op(ch, OP_UNDEF);
        return;
    }
    if k == N_PRIVATE_IDENT {
        cerror(co, n, "a private name is only valid as the left side of 'in'");
        ch_op(ch, OP_UNDEF);
        return;
    }
    if k == N_THIS {
        emit_this(co, n);
        return;
    }
    if k == N_NEW_TARGET {
        // in an arrow, load the enclosing function's captured new.target
        if co.cur.is_arrow {
            FScope* fs = co.cur;
            str nm = "%newtarget";
            if find_local(fs, nm) >= 0 || resolve_upval(fs, nm) >= 0 {
                emit_load_name(co, nm, n);
                return;
            }
        }
        ch_op(ch, OP_NEWTARGET);
        return;
    }
    if k == N_ARRAY {
        bool has_spread = false;
        for i32 i = 0; i < n.kids.len; i++ {
            if (*(n.kids.items + i)).kind == N_SPREAD { has_spread = true; }
        }
        if !has_spread {
            for i32 i = 0; i < n.kids.len; i++ {
                Node* e = *(n.kids.items + i);
                if e.kind == N_HOLE {
                    ch_op(ch, OP_HOLE);
                } else {
                    compile_expr(co, e);
                }
            }
            ch_op_u16(ch, OP_NEWARR, n.kids.len);
            return;
        }
        ch_op_u16(ch, OP_NEWARR, 0);
        for i32 i = 0; i < n.kids.len; i++ {
            Node* e = *(n.kids.items + i);
            if e.kind == N_SPREAD {
                compile_expr(co, e.a);
                ch_op(ch, OP_ARR_SPREAD);
            } else if e.kind == N_HOLE {
                ch_op(ch, OP_HOLE);
                ch_op(ch, OP_ARR_APPEND);
            } else {
                compile_expr(co, e);
                ch_op(ch, OP_ARR_APPEND);
            }
        }
        return;
    }
    if k == N_OBJECT {
        ch_op(ch, OP_NEWOBJ);
        bool proto_seen = false;
        for i32 i = 0; i < n.kids.len; i++ {
            Node* p = *(n.kids.items + i);
            if p.kind == N_SPREAD {
                compile_expr(co, p.a);
                ch_op(ch, OP_OBJ_SPREAD);
                continue;
            }
            if (p.flags & (NF_GETTER | NF_SETTER)) != 0 {
                ch_op(ch, OP_DUP);
                if (p.flags & NF_COMPUTED) != 0 {
                    compile_expr(co, p.a);
                    compile_expr(co, p.b);
                    i32 aop = (p.flags & NF_GETTER) != 0 ? OP_DEFGETTER_DYN : OP_DEFSETTER_DYN;
                    ch_op_u16(ch, aop, 1);   // object-literal accessors are enumerable
                } else {
                    str an = accessor_name(co, (p.flags & NF_GETTER) != 0 ? "get" : "set", p.a);
                    if an.len > 0 { infer_name(p.b, an); }
                    compile_expr(co, p.b);
                    i32 aop = (p.flags & NF_GETTER) != 0 ? OP_DEFGETTER : OP_DEFSETTER;
                    ch_op_u16(ch, aop, prop_key_const(co, p.a));
                    ch_u16(ch, 1);   // object-literal accessors are enumerable
                }
                ch_op(ch, OP_POP);
                continue;
            }
            if (p.flags & NF_COMPUTED) != 0 {
                ch_op(ch, OP_DUP);
                compile_expr(co, p.a);
                if p.b != null { compile_expr(co, p.b); } else { ch_op(ch, OP_UNDEF); }
                // an anonymous function or class takes the key as its name
                bool anon = p.b != null && (p.b.kind == N_FUNCTION || p.b.kind == N_CLASS)
                    && p.b.name.len == 0;
                ch_op_u16(ch, OP_DEFPROP_DYN, anon ? 1 : 0);
                ch_op(ch, OP_POP);
                continue;
            }
            if (p.flags & NF_SHORTHAND) != 0 && p.b != null {
                cerror(co, p, "shorthand initializer outside destructuring");
                continue;
            }
            // `{ __proto__: v }` written as a plain key sets the prototype
            // instead of defining a property. The shorthand, computed, method
            // and accessor spellings all stay ordinary properties.
            if p.b != null && p.a != null
                && (p.a.kind == N_IDENT || p.a.kind == N_STRING)
                && str_equal(p.a.name, "__proto__")
                && (p.b.kind != N_FUNCTION || (p.b.flags & NF_METHOD) == 0) {
                if proto_seen { cerror(co, p, "Duplicate __proto__ fields are not allowed in object literals"); }
                proto_seen = true;
                ch_op(ch, OP_DUP);
                compile_expr(co, p.b);
                ch_op(ch, OP_SETPROTO);
                ch_op(ch, OP_POP);
                continue;
            }
            ch_op(ch, OP_DUP);
            if p.b != null {
                // named evaluation: `{ fn: function(){} }` names the function
                // `fn`. A computed key is only known at run time, so those
                // stay anonymous.
                if p.a != null && (p.a.kind == N_IDENT || p.a.kind == N_STRING) {
                    infer_name(p.b, p.a.name);
                } else if p.a != null && p.a.kind == N_NUMBER {
                    infer_name(p.b, num_key_text(co, p.a.num));
                }
                compile_expr(co, p.b);
            } else {
                emit_load_name(co, p.a.name, p);
            }
            ch_op_u16(ch, OP_DEFPROP, prop_key_const(co, p.a));
            ch_op(ch, OP_POP);
        }
        return;
    }
    if k == N_TEMPLATE {
        bool first = true;
        for i32 i = 0; i < n.kids.len; i++ {
            Node* e = *(n.kids.items + i);
            if e.kind == N_TEMPLATE_ELEM {
                if first || e.name.len > 0 {
                    ch_op_u16(ch, OP_CONST, str_const(co, e.name));
                    if !first { ch_op(ch, OP_ADD); }
                    first = false;
                }
            } else {
                compile_expr(co, e);
                // ToString the substitution (string hint) before joining,
                // so it isn't coerced with the default hint via OP_ADD.
                ch_op(ch, OP_TOSTR);
                if !first { ch_op(ch, OP_ADD); }
                first = false;
            }
        }
        return;
    }
    if k == N_TAGGED_TEMPLATE {
        Node* tag = n.a;
        Node* tmpl = n.b;
        // callee + `this`, mirroring N_CALL: a member tag keeps its receiver
        if tag.kind == N_MEMBER && (tag.flags & NF_PRIVATE) == 0 && tag.a.kind != N_SUPER {
            compile_expr(co, tag.a);
            ch_op_u16(ch, OP_GETMETHOD, name_const(co, tag.name));
        } else if tag.kind == N_INDEX {
            compile_expr(co, tag.a);
            compile_expr(co, tag.b);
            ch_op(ch, OP_GETMETHOD_DYN);
        } else {
            compile_expr(co, tag);
            ch_op(ch, OP_UNDEF);
        }
        // strings array (cooked quasis)
        i32 nq = 0;
        for i32 i = 0; i < tmpl.kids.len; i++ {
            Node* e = *(tmpl.kids.items + i);
            if e.kind == N_TEMPLATE_ELEM {
                ch_op_u16(ch, OP_CONST, str_const(co, e.name));
                nq++;
            }
        }
        ch_op_u16(ch, OP_NEWARR, nq);
        // attach .raw = [raw quasis], leaving the strings array on top
        ch_op(ch, OP_DUP);
        for i32 i = 0; i < tmpl.kids.len; i++ {
            Node* e = *(tmpl.kids.items + i);
            if e.kind == N_TEMPLATE_ELEM {
                ch_op_u16(ch, OP_CONST, str_const(co, e.aux));
            }
        }
        ch_op_u16(ch, OP_NEWARR, nq);
        ch_op(ch, OP_FREEZE);
        ch_op_u16(ch, OP_SETPROP, name_const(co, "raw"));
        ch_op(ch, OP_POP);
        ch_op(ch, OP_FREEZE);
        // substitution expressions as the remaining arguments
        i32 nsub = 0;
        for i32 i = 0; i < tmpl.kids.len; i++ {
            Node* e = *(tmpl.kids.items + i);
            if e.kind != N_TEMPLATE_ELEM {
                compile_expr(co, e);
                nsub++;
            }
        }
        ch_op_u16(ch, OP_CALL, 1 + nsub);
        return;
    }
    if k == N_BIN {
        if n.op == TOK_AMPAMP || n.op == TOK_PIPEPIPE || n.op == TOK_QUESTION_QUESTION {
            i32 jop = OP_JF_KEEP;
            if n.op == TOK_PIPEPIPE { jop = OP_JT_KEEP; }
            if n.op == TOK_QUESTION_QUESTION { jop = OP_JNN_KEEP; }
            compile_expr(co, n.a);
            i32 j = ch_jump(ch, jop);
            compile_expr(co, n.b);
            ch_patch(ch, j);
            return;
        }
        if n.op == TOK_KW_IN && n.a.kind == N_PRIVATE_IDENT {
            // #name in obj: brand check for the private field's hidden atom.
            compile_expr(co, n.b);
            ch_op_u16(ch, OP_HASPRIVATE, private_key_const(co, n.a, n.a.name));
            return;
        }
        compile_expr(co, n.a);
        compile_expr(co, n.b);
        i32 op = bin_op_code(n.op);
        if op < 0 {
            cerror(co, n, "unsupported binary operator");
            return;
        }
        ch_op(ch, op);
        return;
    }
    if k == N_ASSIGN { compile_assign(co, n); return; }
    if k == N_COND {
        compile_expr(co, n.a);
        i32 j1 = ch_jump(ch, OP_JUMPF);
        compile_expr(co, n.b);
        i32 j2 = ch_jump(ch, OP_JUMP);
        ch_patch(ch, j1);
        compile_expr(co, n.c);
        ch_patch(ch, j2);
        return;
    }
    if k == N_UNARY {
        if n.op == TOK_KW_DELETE {
            Node* t = n.a;
            // a private member is not a deletable reference
            if t.kind == N_MEMBER && (t.flags & NF_PRIVATE) != 0 {
                cerror(co, n, "private members cannot be deleted");
                ch_op(ch, OP_FALSE);
                return;
            }
            if (t.kind == N_MEMBER || t.kind == N_INDEX) && chain_has_opt(t) {
                compile_delete_opt(co, t);
            } else if t.kind == N_MEMBER {
                compile_expr(co, t.a);
                ch_op_u16(ch, OP_DELPROP, name_const(co, t.name));
            } else if t.kind == N_INDEX {
                compile_expr(co, t.a);
                compile_expr(co, t.b);
                ch_op(ch, OP_DELINDEX);
            } else {
                // deleting anything that is not a property reference is
                // vacuously successful, but the operand is still evaluated
                compile_expr(co, t);
                ch_op(ch, OP_POP);
                ch_op(ch, OP_TRUE);
            }
            return;
        }
        if n.op == TOK_KW_TYPEOF {
            if n.a.kind == N_IDENT {
                FScope* fs = co.cur;
                // A module import reads from a dependency namespace, not a
                // global, so it must go through the normal expression path.
                bool is_import = co.in_module
                    && strmap_get<ModImport>(&co.mod_imports, n.a.name) != null;
                // Own `arguments` must go through the expression path so it
                // loads the arguments object, not a soft-undefined global.
                bool is_own_args = str_equal(n.a.name, "arguments")
                    && !fs.is_arrow && fs.parent != null
                    && find_local(fs, "arguments") < 0;
                if !is_import && !is_own_args
                   && find_local(fs, n.a.name) < 0 && resolve_upval(fs, n.a.name) < 0 {
                    ch_op_u16(ch, OP_GETGLOBAL_SOFT, name_const(co, n.a.name));
                    ch_op(ch, OP_TYPEOF);
                    return;
                }
            }
            compile_expr(co, n.a);
            ch_op(ch, OP_TYPEOF);
            return;
        }
        if n.op == TOK_KW_VOID {
            compile_expr(co, n.a);
            ch_op(ch, OP_POP);
            ch_op(ch, OP_UNDEF);
            return;
        }
        compile_expr(co, n.a);
        if n.op == TOK_MINUS { ch_op(ch, OP_NEG); return; }
        if n.op == TOK_PLUS { ch_op(ch, OP_TONUMBER); return; }
        if n.op == TOK_BANG { ch_op(ch, OP_NOT); return; }
        if n.op == TOK_TILDE { ch_op(ch, OP_BITNOT); return; }
        cerror(co, n, "unsupported unary operator");
        return;
    }
    if k == N_UPDATE { compile_update(co, n); return; }
    if k == N_MEMBER {
        if n.a.kind == N_SUPER {
            if (n.flags & NF_PRIVATE) != 0 { cerror(co, n, "Unexpected private field"); }
            if !super_available(co) {
                cerror(co, n, "super outside a class method");
                ch_op(ch, OP_UNDEF);
                return;
            }
            emit_super_home(co, n);
            ch_op_u16(ch, OP_GETPROP, name_const(co, n.name));
            return;
        }
        // a private read outside an optional chain; `o?.#x` takes the
        // chain path below, which knows the private link
        if (n.flags & NF_PRIVATE) != 0 && !chain_has_opt(n) {
            compile_expr(co, n.a);
            ch_op_u16(ch, OP_GETPRIVATE, private_key_const(co, n, n.name));
            return;
        }
        if chain_has_opt(n) {
            compile_opt_chain(co, n);
            return;
        }
        compile_expr(co, n.a);
        ch_op_u16(ch, OP_GETPROP, name_const(co, n.name));
        return;
    }
    if k == N_INDEX {
        if n.a.kind == N_SUPER {
            // super[expr]: the computed form of super.name
            if !super_available(co) {
                cerror(co, n, "super outside a class method");
                ch_op(ch, OP_UNDEF);
                return;
            }
            emit_super_home(co, n);
            compile_expr(co, n.b);
            ch_op(ch, OP_GETINDEX);
            return;
        }
        if chain_has_opt(n) {
            compile_opt_chain(co, n);
            return;
        }
        compile_expr(co, n.a);
        compile_expr(co, n.b);
        ch_op(ch, OP_GETINDEX);
        return;
    }
    if k == N_CALL { compile_call(co, n); return; }
    if k == N_NEW {
        compile_expr(co, n.a);
        i32 c = compile_args(co, &n.kids);
        if c >= 0 { ch_op_u16(ch, OP_NEW, c); } else { ch_op(ch, OP_NEW_ARRAY); }
        return;
    }
    if k == N_SEQ {
        for i32 i = 0; i < n.kids.len; i++ {
            compile_expr(co, *(n.kids.items + i));
            if i + 1 < n.kids.len { ch_op(ch, OP_POP); }
        }
        return;
    }
    if k == N_FUNCTION {
        compile_function(co, n, true);
        return;
    }
    if k == N_CLASS {
        compile_class_expr(co, n);
        return;
    }
    if k == N_YIELD {
        if !co.cur.is_gen || co.in_static_block {
            cerror(co, n, "yield outside a generator");
            ch_op(ch, OP_UNDEF);
            return;
        }
        if co.in_params {
            cerror(co, n, "Yield expression not allowed in formal parameter");
            ch_op(ch, OP_UNDEF);
            return;
        }
        if (n.flags & NF_DELEGATE) != 0 {
            // yield*: iterate the operand, yielding each value; the expression
            // result is the inner iterator's return value. Whatever resumes
            // this generator is sent on into the delegate's next().
            // In an async generator the delegate is walked with the async
            // protocol: its next() hands back a promise, so each step is
            // awaited. A sync iterable still works, since OP_GET_AITER falls
            // back to Symbol.iterator and awaiting a plain result is a no-op.
            bool adelegate = co.cur.is_async;
            compile_expr(co, n.a);
            // [iter, wrapped]: in an async generator the delegate may be a
            // sync iterator, whose values are then awaited
            if adelegate { ch_op(ch, OP_GET_AITER_W); }
            else { ch_op(ch, OP_GET_ITER); ch_op(ch, OP_FALSE); }
            i32 t_wrapped = alloc_slot(co.cur);
            ch_op_u16(ch, OP_SETLOCAL, t_wrapped);
            ch_op(ch, OP_POP);
            i32 t_it = alloc_slot(co.cur);
            ch_op_u16(ch, OP_SETLOCAL, t_it);
            ch_op(ch, OP_POP);
            // the next method is read once, as the language's iterator record has it
            i32 t_next = alloc_slot(co.cur);
            ch_op_u16(ch, OP_GETLOCAL, t_it);
            ch_op_u16(ch, OP_GETPROP, name_const(co, "next"));
            ch_op_u16(ch, OP_SETLOCAL, t_next);
            ch_op(ch, OP_POP);
            // What resumed this generator: the input, and the completion's
            // kind (0 next, 1 throw, 2 return), which the loop forwards to
            // the delegate's method of that name.
            i32 t_sent = alloc_slot(co.cur);
            ch_op(ch, OP_UNDEF);
            ch_op_u16(ch, OP_SETLOCAL, t_sent);
            ch_op(ch, OP_POP);
            i32 t_mode = alloc_slot(co.cur);
            ch_op_u16(ch, OP_CONST, ch_add_const(ch, value_int(0)));
            ch_op_u16(ch, OP_SETLOCAL, t_mode);
            ch_op(ch, OP_POP);
            // the delegate's throw/return, read once each time one is
            // needed: the language reads the property once and calls what
            // it found, and a test with a getter on it can tell
            i32 t_meth = alloc_slot(co.cur);
            // never set: the close on a missing throw method always runs
            i32 t_done = alloc_slot(co.cur);
            ch_op(ch, OP_FALSE);
            ch_op_u16(ch, OP_SETLOCAL, t_done);
            ch_op(ch, OP_POP);

            i32 lstart = ch_pos(ch);
            ch_op_u16(ch, OP_GETLOCAL, t_mode);
            ch_op_u16(ch, OP_CONST, ch_add_const(ch, value_int(1)));
            ch_op(ch, OP_SEQ);
            i32 jthrow = ch_jump(ch, OP_JUMPT);
            ch_op_u16(ch, OP_GETLOCAL, t_mode);
            ch_op_u16(ch, OP_CONST, ch_add_const(ch, value_int(2)));
            ch_op(ch, OP_SEQ);
            i32 jret = ch_jump(ch, OP_JUMPT);
            // next.call(it, sent). In an async generator the delegate is
            // walked with the async protocol: each result is awaited, and a
            // wrapped sync iterator's values too.
            ch_op_u16(ch, OP_GETLOCAL, t_next);
            ch_op_u16(ch, OP_GETLOCAL, t_it);
            ch_op_u16(ch, OP_GETLOCAL, t_sent);
            ch_op_u16(ch, OP_CALL, 1);
            if adelegate { ch_op(ch, OP_AWAIT); }
            ch_op(ch, OP_ITER_CHECK);          // [res]
            ch_op(ch, OP_DUP);
            ch_op_u16(ch, OP_GETPROP, name_const(co, "done"));
            i32 jdone = ch_jump(ch, OP_JUMPT);
            ch_op_u16(ch, OP_GETPROP, name_const(co, "value"));
            emit_await_if_wrapped(co, t_wrapped);
            i32 lyield = ch_pos(ch);           // [value]
            ch_op(ch, OP_YIELD_DELEGATE);      // resumes with [input, kind]
            ch_op_u16(ch, OP_SETLOCAL, t_mode);
            ch_op(ch, OP_POP);
            ch_op_u16(ch, OP_SETLOCAL, t_sent);
            ch_op(ch, OP_POP);
            ch_op_u16(ch, OP_JUMP, lstart);
            ch_patch(ch, jdone);               // [res]: the delegate is done
            ch_op_u16(ch, OP_GETPROP, name_const(co, "value"));
            emit_await_if_wrapped(co, t_wrapped);
            i32 jend = ch_jump(ch, OP_JUMP);

            // throw(sent): forwarded when the delegate has the method; else
            // the delegate is closed and the caller gets a TypeError
            ch_patch(ch, jthrow);
            ch_op_u16(ch, OP_GETLOCAL, t_it);
            ch_op_u16(ch, OP_GETPROP, name_const(co, "throw"));
            ch_op_u16(ch, OP_SETLOCAL, t_meth);
            // undefined or null means the delegate has no throw; anything
            // else has to be callable, and is an error on its own if not
            i32 jnothrow = ch_jump(ch, OP_JUMP_NULLISH);
            ch_op(ch, OP_TYPEOF);
            ch_op_u16(ch, OP_CONST, str_const(co, "function"));
            ch_op(ch, OP_SEQ);
            i32 jthrowok = ch_jump(ch, OP_JUMPT);
            ch_op_u16(ch, OP_GETGLOBAL, name_const(co, "TypeError"));
            ch_op_u16(ch, OP_CONST, str_const(co, "The iterator's 'throw' property is not a function."));
            ch_op_u16(ch, OP_NEW, 1);
            ch_op(ch, OP_THROW);
            ch_patch(ch, jthrowok);
            ch_op_u16(ch, OP_GETLOCAL, t_meth);
            ch_op_u16(ch, OP_GETLOCAL, t_it);
            ch_op_u16(ch, OP_GETLOCAL, t_sent);
            ch_op_u16(ch, OP_CALL, 1);
            if adelegate { ch_op(ch, OP_AWAIT); }
            ch_op(ch, OP_ITER_CHECK);          // [res]
            ch_op(ch, OP_DUP);
            ch_op_u16(ch, OP_GETPROP, name_const(co, "done"));
            i32 jthrowdone = ch_jump(ch, OP_JUMPT);
            ch_op_u16(ch, OP_GETPROP, name_const(co, "value"));
            emit_await_if_wrapped(co, t_wrapped);
            ch_op_u16(ch, OP_JUMP, lyield);
            ch_patch(ch, jthrowdone);          // [res]
            ch_op_u16(ch, OP_GETPROP, name_const(co, "value"));
            emit_await_if_wrapped(co, t_wrapped);
            i32 jend2 = ch_jump(ch, OP_JUMP);
            ch_patch(ch, jnothrow);
            ch_op_u16(ch, OP_GETLOCAL, t_it);
            ch_op_u16(ch, OP_ITER_CLOSE, t_done);
            ch_op_u16(ch, OP_GETGLOBAL, name_const(co, "TypeError"));
            ch_op_u16(ch, OP_CONST, str_const(co, "The iterator does not provide a 'throw' method."));
            ch_op_u16(ch, OP_NEW, 1);
            ch_op(ch, OP_THROW);

            // return(sent): forwarded when the delegate has the method, and
            // a done result returns from this generator; without the method
            // the generator returns what it was sent. Either way its own
            // finally blocks run.
            ch_patch(ch, jret);
            ch_op_u16(ch, OP_GETLOCAL, t_it);
            ch_op_u16(ch, OP_GETPROP, name_const(co, "return"));
            ch_op_u16(ch, OP_SETLOCAL, t_meth);
            i32 jnoret = ch_jump(ch, OP_JUMP_NULLISH);
            ch_op(ch, OP_TYPEOF);
            ch_op_u16(ch, OP_CONST, str_const(co, "function"));
            ch_op(ch, OP_SEQ);
            i32 jretok = ch_jump(ch, OP_JUMPT);
            ch_op_u16(ch, OP_GETGLOBAL, name_const(co, "TypeError"));
            ch_op_u16(ch, OP_CONST, str_const(co, "The iterator's 'return' property is not a function."));
            ch_op_u16(ch, OP_NEW, 1);
            ch_op(ch, OP_THROW);
            ch_patch(ch, jretok);
            ch_op_u16(ch, OP_GETLOCAL, t_meth);
            ch_op_u16(ch, OP_GETLOCAL, t_it);
            ch_op_u16(ch, OP_GETLOCAL, t_sent);
            ch_op_u16(ch, OP_CALL, 1);
            if adelegate { ch_op(ch, OP_AWAIT); }
            ch_op(ch, OP_ITER_CHECK);          // [res]
            ch_op(ch, OP_DUP);
            ch_op_u16(ch, OP_GETPROP, name_const(co, "done"));
            i32 jretdone = ch_jump(ch, OP_JUMPT);
            ch_op_u16(ch, OP_GETPROP, name_const(co, "value"));
            emit_await_if_wrapped(co, t_wrapped);
            ch_op_u16(ch, OP_JUMP, lyield);
            ch_patch(ch, jretdone);            // [res]
            ch_op_u16(ch, OP_GETPROP, name_const(co, "value"));
            emit_await_if_wrapped(co, t_wrapped);
            inline_finallys(co, 0);
            ch_op(ch, OP_RETURN);
            ch_patch(ch, jnoret);
            ch_op_u16(ch, OP_GETLOCAL, t_sent);
            inline_finallys(co, 0);
            ch_op(ch, OP_RETURN);

            ch_patch(ch, jend);                // [value]: the yield* result
            ch_patch(ch, jend2);
            co.cur.cur_slots -= 6;
            return;
        }
        if n.a != null {
            compile_expr(co, n.a);
        } else {
            ch_op(ch, OP_UNDEF);
        }
        ch_op(ch, OP_YIELD);
        return;
    }
    if k == N_AWAIT {
        if !co.cur.is_async || co.in_static_block {
            cerror(co, n, "await outside an async function");
            ch_op(ch, OP_UNDEF);
            return;
        }
        if co.in_params {
            cerror(co, n, "Illegal await-expression in formal parameters of async function");
            ch_op(ch, OP_UNDEF);
            return;
        }
        compile_expr(co, n.a);
        ch_op(ch, OP_AWAIT);
        return;
    }
    cerror(co, n, "expression not supported yet");
    ch_op(ch, OP_UNDEF);
}

// --- functions ---------------------------------------------------------------------

// [value] -> [value]: awaits it when the iterator it came from wrapped a
// sync iterator, as the language's async-from-sync iterator does.
private void emit_await_if_wrapped(Compiler* co, i32 t_wrapped) {
    Chunk* ch = &co.cur.ch;
    ch_op_u16(ch, OP_GETLOCAL, t_wrapped);
    i32 j = ch_jump(ch, OP_JUMPF);
    ch_op(ch, OP_AWAIT);
    ch_patch(ch, j);
}

// A parameter list with a default, a pattern or a rest element binds
// left to right, the way the language does: a default that reads itself
// or a later parameter throws a ReferenceError. The incoming values wait
// in hidden slots while every parameter holds a hole (a captured one a
// cell with a hole, so a closure made in a default already sees the
// cell), and each is bound in turn; once bound, its reads need no check.
private void bind_params_in_order(Compiler* co, FScope* fs, Node* f, i32 n_params) {
    Chunk* ch = &fs.ch;
    // the names a pattern binds start in TDZ as well
    for i32 i = 0; i < n_params; i++ {
        Node* prm = *(f.kids.items + i);
        if prm.a.kind != N_IDENT { declare_pattern(co, prm.a, 0); }
    }
    i32 first_tmp = fs.cur_slots;
    for i32 i = 0; i < n_params; i++ {
        i32 t = alloc_slot(fs);
        ch_op_u16(ch, OP_GETLOCAL, i);
        ch_op_u16(ch, OP_SETLOCAL, t);
        ch_op(ch, OP_POP);
    }
    for i32 i = 0; i < n_params; i++ {
        CBind b = vec_get(&fs.binds, i);
        ch_op_u16(ch, b.is_cell ? OP_NEWCELL_HOLE : OP_SETHOLE, b.slot);
    }
    for i32 i = 0; i < n_params; i++ {
        Node* prm = *(f.kids.items + i);
        ch_op_u16(ch, OP_GETLOCAL, first_tmp + i);
        if prm.b != null {
            ch_op(ch, OP_DUP);
            ch_op(ch, OP_UNDEF);
            ch_op(ch, OP_SEQ);
            i32 j = ch_jump(ch, OP_JUMPF);
            ch_op(ch, OP_POP);
            // named evaluation: an anonymous default takes the parameter's name
            if prm.a != null && prm.a.kind == N_IDENT { infer_name(prm.b, prm.a.name); }
            compile_expr(co, prm.b);
            ch_patch(ch, j);
        }
        emit_init_binding(co, i);
        if prm.a.kind == N_IDENT {
            CBind* bp = fs.binds.data + i;
            bp.tdz = false;
        } else {
            CBind pb = vec_get(&fs.binds, i);
            ch_op_u16(ch, pb.is_cell ? OP_GETCELL : OP_GETLOCAL, pb.slot);
            compile_destructure(co, prm.a, true);
            Vec<str> names = vec_new<str>(4);
            collect_pattern_names(prm.a, &names);
            for i32 k = 0; k < names.len; k++ {
                i32 li = find_local(fs, vec_get(&names, k));
                if li >= 0 {
                    CBind* np = fs.binds.data + li;
                    np.tdz = false;
                }
            }
            vec_free(&names);
        }
    }
    // the hidden slots are dead from here on
    fs.cur_slots = first_tmp;
}

// Compiles f into a template. `fields` (class members) inject
// this-assignments into the body after a leading super() call.
private FnTemplate* compile_function_tmpl(Compiler* co, Node* f, Node** fields, i32 n_fields, bool self_name) {
    FScope fs;
    fscope_init(&fs, co.cur, (f.flags & NF_ARROW) != 0);
    fs.is_gen = (f.flags & NF_GENERATOR) != 0;
    fs.is_async = (f.flags & NF_ASYNC) != 0;
    fs.super_call_ok = co.next_is_derived_ctor;
    co.next_is_derived_ctor = false;
    if (f.flags & NF_ARROW) == 0 { fs.static_home = co.next_static_home; }
    co.next_static_home = false;
    bool saved_static_block = co.in_static_block;
    bool saved_in_params = co.in_params;
    co.in_static_block = false;
    co.in_params = false;
    co.cur = &fs;
    scan_inner(&fs.inner, f, true);
    for i32 i = 0; i < n_fields; i++ {
        // a private method's body was compiled with the class, not here
        if member_is_private_method(*(fields + i)) { continue; }
        scan_inner(&fs.inner, *(fields + i), true);
    }

    // A repeated parameter name is only tolerated in the simple parameter list
    // of an ordinary function. A method or arrow always requires unique names,
    // as does any list carrying a default, a rest element or a pattern.
    bool simple_params = true;
    for i32 i = 0; i < f.kids.len; i++ {
        Node* prm = *(f.kids.items + i);
        if prm.b != null || (prm.flags & NF_REST) != 0
            || prm.a == null || prm.a.kind != N_IDENT { simple_params = false; }
    }
    // strict-mode code stays strict inside; a sloppy function body may
    // opt in with a directive
    bool saved_strict = co.strict;
    if !co.strict && f.a != null && f.a.kind == N_BLOCK && has_use_strict(&f.a.kids) {
        co.strict = true;
    }
    // the directive is refused when the parameters are anything but names
    if !simple_params && f.a != null && f.a.kind == N_BLOCK && has_use_strict(&f.a.kids) {
        cerror(co, f, "Illegal 'use strict' directive in function with non-simple parameter list");
    }
    // a strict function may not be named eval or arguments
    if f.name.len > 0 && (f.flags & (NF_METHOD | NF_ARROW | NF_NAME_INFERRED)) == 0 {
        check_strict_binding(co, f, f.name);
    }
    if !simple_params || co.strict || (f.flags & (NF_ARROW | NF_METHOD)) != 0 {
        Vec<str> pnames = vec_new<str>(4);
        for i32 i = 0; i < f.kids.len; i++ {
            collect_pattern_names((*(f.kids.items + i)).a, &pnames);
        }
        for i32 i = 0; i < pnames.len; i++ {
            str nm = vec_get(&pnames, i);
            for i32 j = 0; j < i; j++ {
                if str_equal(vec_get(&pnames, j), nm) {
                    redeclared(co, f, nm);
                    break;
                }
            }
        }
        vec_free(&pnames);
    }

    // params. A simple list is bound by the call itself; a list with a
    // default, a pattern or a rest element binds its names one at a time,
    // each in TDZ until its turn.
    i32 n_params = 0;
    for i32 i = 0; i < f.kids.len; i++ {
        Node* prm = *(f.kids.items + i);
        if (prm.flags & NF_REST) != 0 {
            fs.has_rest = true;
            if i != f.kids.len - 1 {
                cerror(co, prm, "rest parameter must be last");
            }
        }
        if prm.a.kind == N_IDENT {
            check_strict_binding(co, prm.a, prm.a.name);
            ignore declare(co, prm.a.name, false, !simple_params);
        } else {
            ignore declare(co, hidden_name(co, "%p", i), false, false);
        }
        n_params++;
    }
    if simple_params {
        // boxing of captured params
        for i32 i = 0; i < n_params; i++ {
            CBind b = vec_get(&fs.binds, i);
            if b.is_cell {
                ch_op_u16(&fs.ch, OP_CELLIFY, b.slot);
            }
        }
    } else {
        // a default may not yield or await: those belong to the body
        co.in_params = true;
        bind_params_in_order(co, &fs, f, n_params);
        co.in_params = false;
    }
    // a named function EXPRESSION binds its own name inside its body (for
    // recursion), referring to the function itself; the name does not leak to
    // the enclosing scope. Skipped if a parameter shadows it. The binding is
    // declared non-const: the spec makes it immutable (assignment is a no-op
    // in sloppy mode), but rejecting a write at compile time would break a
    // whole module, so a stray write is tolerated as a plain reassignment.
    if self_name && f.name.len > 0 && (f.flags & NF_ARROW) == 0
       && find_local(&fs, f.name) < 0 {
        i32 bi = declare(co, f.name, false, false);
        CBind b = vec_get(&fs.binds, bi);
        ch_op(&fs.ch, OP_CURFUNC);
        ch_op_u16(&fs.ch, OP_SETLOCAL, b.slot);
        ch_op(&fs.ch, OP_POP);
        if b.is_cell {
            ch_op_u16(&fs.ch, OP_CELLIFY, b.slot);
        }
    }
    // implicit `this` binding for arrows below
    if !fs.is_arrow && strmap_get<i32>(&fs.inner, "this") != null {
        i32 bi = declare(co, "this", true, false);
        CBind b = vec_get(&fs.binds, bi);
        ch_op(&fs.ch, OP_THIS);
        ch_op_u16(&fs.ch, OP_SETLOCAL, b.slot);
        ch_op(&fs.ch, OP_POP);
        if b.is_cell {
            ch_op_u16(&fs.ch, OP_CELLIFY, b.slot);
        }
    }
    // implicit `new.target` binding, captured lexically by nested arrows.
    if !fs.is_arrow && strmap_get<i32>(&fs.inner, "%newtarget") != null {
        i32 bi = declare(co, "%newtarget", true, false);
        CBind b = vec_get(&fs.binds, bi);
        ch_op(&fs.ch, OP_NEWTARGET);
        ch_op_u16(&fs.ch, OP_SETLOCAL, b.slot);
        ch_op(&fs.ch, OP_POP);
        if b.is_cell {
            ch_op_u16(&fs.ch, OP_CELLIFY, b.slot);
        }
    }
    // implicit `arguments` binding, so nested arrows capture it lexically.
    // Skip if a parameter/local already named `arguments` shadows it.
    if !fs.is_arrow && strmap_get<i32>(&fs.inner, "arguments") != null
       && find_local(&fs, "arguments") < 0 {
        i32 bi = declare(co, "arguments", true, false);
        CBind b = vec_get(&fs.binds, bi);
        ch_op(&fs.ch, OP_ARGUMENTS);
        ch_op_u16(&fs.ch, OP_SETLOCAL, b.slot);
        ch_op(&fs.ch, OP_POP);
        if b.is_cell {
            ch_op_u16(&fs.ch, OP_CELLIFY, b.slot);
        }
        fs.needs_arguments = true;
    }

    if f.a != null && f.a.kind == N_BLOCK {
        hoist_vars(co, f.a);
        // a generator binds its parameters at the call and waits here for
        // the first next(); an error above belongs to the caller
        if fs.is_gen { ch_op(&fs.ch, OP_GEN_START); }
        co.outer_names.len = 0;
        for i32 i = 0; i < f.kids.len; i++ {
            collect_pattern_names((*(f.kids.items + i)).a, &co.outer_names);
        }
        co.outer_is_body = true;
        compile_block_stmts_ex(co, &f.a.kids, fields, n_fields);
        ch_op(&fs.ch, OP_UNDEF);
        ch_op(&fs.ch, OP_RETURN);
    } else if f.a != null {
        compile_expr(co, f.a);
        ch_op(&fs.ch, OP_RETURN);
    } else {
        ch_op(&fs.ch, OP_UNDEF);
        ch_op(&fs.ch, OP_RETURN);
    }

    FnTemplate* t = chunk_finish(&fs.ch, f.name, n_params, fs.n_slots, fs.has_rest,
        fs.is_gen, fs.is_async);
    t.needs_arguments = fs.needs_arguments;
    t.sloppy = !co.strict;
    co.strict = saved_strict;
    // arrows and shorthand methods have no [[Construct]]; the class ctor is
    // parsed as a method, so compile_class_expr clears this again for it
    if (f.flags & (NF_ARROW | NF_METHOD)) != 0 { t.not_ctor = true; }
    t.src_name = co.src_name;
    // what toString hands back, taken from the span the parser recorded
    t.src_text = co.src;
    t.src_start = f.span.start;
    t.src_end = f.span.end;
    // Function.length: count leading params up to the first with a
    // default value or the rest parameter.
    i32 arity = 0;
    for i32 i = 0; i < f.kids.len; i++ {
        Node* prm = *(f.kids.items + i);
        if (prm.flags & NF_REST) != 0 { break; }
        if prm.b != null { break; }
        arity++;
    }
    t.arity = arity;
    co.in_static_block = saved_static_block;
    co.in_params = saved_in_params;
    co.cur = fs.parent;
    fscope_free(&fs);
    return t;
}

private void compile_function(Compiler* co, Node* f, bool self_name) {
    // A method's name is its property key, not a binding: `{ f() { f() } }`
    // calls the outer f. Only a named function expression sees itself.
    if (f.flags & NF_METHOD) != 0 { self_name = false; }
    FnTemplate* t = compile_function_tmpl(co, f, null, 0, self_name);
    vec_push(&co.cur.ch.subs, t);
    ch_op_u16(&co.cur.ch, OP_CLOSURE, co.cur.ch.subs.len - 1);
}

// --- classes -----------------------------------------------------------------------

private Node* cnode(Compiler* co, i32 kind) {
    Node* n = cast(Node*, bump_alloc(co.arena, cast(i32, sizeof(Node))));
    n.kind = kind;
    return n;
}

private NodeList clist1(Compiler* co, Node* n0) {
    NodeList l;
    l.len = 1;
    l.items = cast(Node**, bump_alloc(co.arena, 8));
    *(l.items) = n0;
    return l;
}

// constructor(...args) { super(...args); }  — or an empty body for
// base classes.
private Node* build_default_ctor(Compiler* co, bool derived) {
    Node* f = cnode(co, N_FUNCTION);
    Node* body = cnode(co, N_BLOCK);
    f.a = body;
    if !derived { return f; }
    Node* prm = cnode(co, N_PARAM);
    prm.flags = NF_REST;
    Node* pid = cnode(co, N_IDENT);
    pid.name = "%args";
    prm.a = pid;
    f.kids = clist1(co, prm);
    Node* call = cnode(co, N_CALL);
    call.a = cnode(co, N_SUPER);
    Node* sp = cnode(co, N_SPREAD);
    Node* aid = cnode(co, N_IDENT);
    aid.name = "%args";
    sp.a = aid;
    call.kids = clist1(co, sp);
    Node* st = cnode(co, N_EXPR_STMT);
    st.a = call;
    body.kids = clist1(co, st);
    return f;
}

// Method or field is syntax, not the initializer's type: `m() {}` is a method,
// while `m = function () {}` and `m = () => {}` are fields that happen to hold a
// function — own properties on the instance, and an arrow there closes over the
// constructor's `this`. The parser marks the method form with NF_METHOD.
// A private method or accessor declared on instances belongs to each
// object rather than to the prototype, so the constructor installs it.
private bool member_is_private_method(Node* m) {
    if m == null || m.kind != N_CLASS_MEMBER { return false; }
    if (m.flags & NF_STATIC) != 0 { return false; }
    if m.a == null || m.a.kind != N_PRIVATE_IDENT { return false; }
    return m.b != null && m.b.kind == N_FUNCTION && (m.b.flags & NF_METHOD) != 0;
}

// The OP_DEFPRIVATE kind of a class member: a getter, a setter, a method,
// or a field.
private i32 private_def_kind(Node* m) {
    if (m.flags & NF_GETTER) != 0 { return 1; }
    if (m.flags & NF_SETTER) != 0 { return 2; }
    if m.b != null && m.b.kind == N_FUNCTION && (m.b.flags & NF_METHOD) != 0 { return 0; }
    return 3;
}

private void emit_def_private(Compiler* co, Node* m) {
    Chunk* ch = &co.cur.ch;
    ch_op_u16(ch, OP_DEFPRIVATE, prop_key_const(co, m.a));
    ch_u16(ch, cast(u16, private_def_kind(m)));
}

// A static data member: a static field, as opposed to a static method or
// accessor. A field whose initializer happens to be a function or an arrow
// is still a field.
private bool member_is_static_field(Node* m) {
    if m == null || m.kind != N_CLASS_MEMBER { return false; }
    if (m.flags & NF_STATIC) == 0 { return false; }
    if (m.flags & (NF_GETTER | NF_SETTER)) != 0 { return false; }
    return m.b == null || m.b.kind != N_FUNCTION || (m.b.flags & NF_METHOD) == 0;
}

private bool member_is_field(Node* m) {
    if m.kind != N_CLASS_MEMBER { return false; }
    if (m.flags & NF_STATIC) != 0 { return false; }
    if m.b != null && m.b.kind == N_FUNCTION && (m.b.flags & NF_METHOD) != 0 { return false; }
    return true;
}

// The names a class element may not have. A key that is a name or a
// string counts; a computed key is only known at run time.
private bool member_named(Node* m, str name) {
    if (m.flags & NF_COMPUTED) != 0 || m.a == null { return false; }
    return (m.a.kind == N_IDENT || m.a.kind == N_STRING) && str_equal(m.a.name, name);
}

// Whether `n` refers to `arguments`, looking through arrows but not into
// other functions, which have their own.
private bool contains_arguments(Node* n) {
    if n == null { return false; }
    if n.kind == N_FUNCTION && (n.flags & NF_ARROW) == 0 { return false; }
    if n.kind == N_IDENT { return str_equal(n.name, "arguments"); }
    if (n.kind == N_PROP || n.kind == N_CLASS_MEMBER || n.kind == N_PATTERN_PROP)
        && (n.flags & NF_COMPUTED) == 0 {
        // a literal key is a name, not a reference, unless it is shorthand
        // for the value
        if n.kind == N_PROP && n.b == null { return contains_arguments(n.a); }
        return contains_arguments(n.b);
    }
    if contains_arguments(n.a) || contains_arguments(n.b)
        || contains_arguments(n.c) || contains_arguments(n.d) { return true; }
    for i32 i = 0; i < n.kids.len; i++ {
        if contains_arguments(*(n.kids.items + i)) { return true; }
    }
    return false;
}

// Whether `n` calls super(), looking through arrows but not into other
// functions.
private bool contains_super_call(Node* n) {
    if n == null { return false; }
    if n.kind == N_FUNCTION && (n.flags & NF_ARROW) == 0 { return false; }
    if n.kind == N_CALL && n.a != null && n.a.kind == N_SUPER { return true; }
    if contains_super_call(n.a) || contains_super_call(n.b)
        || contains_super_call(n.c) || contains_super_call(n.d) { return true; }
    for i32 i = 0; i < n.kids.len; i++ {
        if contains_super_call(*(n.kids.items + i)) { return true; }
    }
    return false;
}

// A field initializer or static block is not a function of its own: it may
// not mention `arguments`, and may not call super().
private void class_init_rules(Compiler* co, Node* at, Node* body) {
    if contains_arguments(body) {
        cerror(co, at, "'arguments' is not allowed in class field initializer or static initialization block");
    }
    if contains_super_call(body) { cerror(co, at, "'super' keyword unexpected here"); }
}

private void class_member_rules(Compiler* co, Node* m) {
    bool is_static = (m.flags & NF_STATIC) != 0;
    bool is_method = m.b != null && m.b.kind == N_FUNCTION && (m.b.flags & NF_METHOD) != 0;
    bool is_acc = (m.flags & (NF_GETTER | NF_SETTER)) != 0;
    if !is_method && m.b != null { class_init_rules(co, m, m.b); }
    if m.a != null && m.a.kind == N_PRIVATE_IDENT && str_equal(m.a.name, "constructor") {
        cerror(co, m, "Classes may not have a private field named '#constructor'");
        return;
    }
    if !is_static && member_named(m, "constructor") {
        if !is_method { cerror(co, m, "Classes may not have a field named 'constructor'"); }
        else if is_acc { cerror(co, m, "Class constructor may not be an accessor"); }
        else if (m.b.flags & NF_GENERATOR) != 0 { cerror(co, m, "Class constructor may not be a generator"); }
        else if (m.b.flags & NF_ASYNC) != 0 { cerror(co, m, "Class constructor may not be an async method"); }
    }
    if is_static && member_named(m, "prototype") {
        cerror(co, m, "Classes may not have a static property named 'prototype'");
    }
    if is_static && !is_method && member_named(m, "constructor") {
        cerror(co, m, "Classes may not have a static property named 'constructor'");
    }
}

// Leaves the class constructor function on the stack.
private void compile_class_expr(Compiler* co, Node* c) {
    FScope* fs = co.cur;
    Chunk* ch = &fs.ch;
    bool derived = c.a != null;
    bool saved_strict = co.strict;
    co.strict = true;   // class bodies are strict-mode code

    fs.depth++;
    i32 saved_binds = fs.binds.len;
    i32 saved_slots = fs.cur_slots;

    if derived {
        compile_expr(co, c.a);
        i32 bi = declare(co, "%super", true, false);
        CBind* bp = fs.binds.data + bi;
        bp.is_cell = true;
        ch_op_u16(ch, OP_NEWCELL_UNDEF, bp.slot);
        ch_op_u16(ch, OP_SETCELL, bp.slot);
        ch_op(ch, OP_POP);
    }

    // The class's private names, visible to the body and anything nested in
    // it. The heritage above was compiled outside them, as the language says.
    PrivScope ps;
    ps.id = g_class_seq;
    g_class_seq++;
    // the syntactic name; a name taken from the binding does not count
    ps.class_name = c.name.len > 0 && (c.flags & NF_NAME_INFERRED) == 0 ? c.name : "anonymous";
    vec_init<PrivName>(&ps.names, 4);
    for i32 i = 0; i < c.kids.len; i++ {
        Node* m = *(c.kids.items + i);
        if m.kind == N_CLASS_MEMBER && m.a != null && m.a.kind == N_PRIVATE_IDENT {
            bool is_fn = m.b != null && m.b.kind == N_FUNCTION && (m.b.flags & NF_METHOD) != 0;
            // a private name is declared once, except a getter with its setter
            for i32 j = 0; j < ps.names.len; j++ {
                PrivName seen = vec_get(&ps.names, j);
                if !str_equal(seen.name, m.a.name) { continue; }
                i32 acc = m.flags & (NF_GETTER | NF_SETTER);
                bool pair = acc != 0 && seen.acc != 0 && acc != seen.acc
                    && seen.is_static == ((m.flags & NF_STATIC) != 0);
                if !pair || seen.paired {
                    string msg = format("Identifier '#{}' has already been declared", m.a.name);
                    str mv = msg;
                    cerror(co, m, mv);
                    free(msg);
                } else {
                    PrivName* sp = ps.names.data + j;
                    sp.paired = true;
                }
            }
            PrivName pn;
            pn.name = m.a.name;
            pn.kind = !is_fn ? 0 : ((m.flags & NF_STATIC) != 0 ? 2 : 1);
            pn.acc = m.flags & (NF_GETTER | NF_SETTER);
            pn.is_static = (m.flags & NF_STATIC) != 0;
            pn.paired = false;
            vec_push(&ps.names, pn);
        }
    }
    vec_push(&co.priv_scopes, ps);

    // Inner class-name binding: inside the class body the class name refers
    // to the class itself. It stays in TDZ while the elements are defined —
    // a computed key may not read it — and is initialized before the static
    // initializers run. `declare` cellifies it automatically when a method
    // or field initializer closes over it.
    i32 name_bind = 0 - 1;
    if c.name.len > 0 {
        name_bind = declare(co, c.name, true, true);
        CBind* nb = fs.binds.data + name_bind;
        if nb.is_cell { ch_op_u16(ch, OP_NEWCELL_HOLE, nb.slot); }
        else { ch_op_u16(ch, OP_SETHOLE, nb.slot); }
    }

    // The instance elements, in the order the constructor installs them:
    // every private method first, then the fields. `elem_ix` gives a member
    // its place in that list, which names its hidden bindings.
    Vec<NodePtr> fields = vec_new<NodePtr>(4);
    Vec<i32> elem_ix = vec_new<i32>(4);
    for i32 i = 0; i < c.kids.len; i++ { vec_push(&elem_ix, 0 - 1); }
    Node* ctor_member = null;
    bool has_static = false;
    for i32 i = 0; i < c.kids.len; i++ {
        Node* m = *(c.kids.items + i);
        if !member_is_private_method(m) { continue; }
        class_member_rules(co, m);
        vec_set(&elem_ix, i, fields.len);
        vec_push(&fields, m);
    }
    for i32 i = 0; i < c.kids.len; i++ {
        Node* m = *(c.kids.items + i);
        if m.kind == N_STATIC_BLOCK {
            class_init_rules(co, m, m.a);
            has_static = true;
            continue;
        }
        if m.kind != N_CLASS_MEMBER || member_is_private_method(m) { continue; }
        class_member_rules(co, m);
        if (m.flags & NF_STATIC) == 0 && m.b != null && m.b.kind == N_FUNCTION
            && (m.flags & (NF_GETTER | NF_SETTER)) == 0 && member_named(m, "constructor") {
            if ctor_member != null { cerror(co, m, "A class may only have one constructor"); }
            ctor_member = m;
            continue;
        }
        if member_is_field(m) {
            vec_set(&elem_ix, i, fields.len);
            vec_push(&fields, m);
            continue;
        }
        // a static data member (static field) also runs with `this` = the class
        if member_is_static_field(m) { has_static = true; }
    }

    // constructor template
    Node* ctor_fn = null;
    if ctor_member != null {
        ctor_fn = ctor_member.b;
    } else {
        ctor_fn = build_default_ctor(co, derived);
    }
    // A computed field key is evaluated once, when the class is defined, and
    // the constructor reads the result from a hidden binding each time it
    // defines the field. The bindings are declared here so the constructor
    // can capture them; the element pass below fills them in source order.
    for i32 i = 0; i < fields.len; i++ {
        Node* m = vec_get(&fields, i);
        str hn = "";
        if member_is_private_method(m) { hn = hidden_name(co, "%pm", i); }
        else if (m.flags & NF_COMPUTED) != 0 { hn = hidden_name(co, "%fk", i); }
        if hn.len == 0 { continue; }
        i32 bi = declare(co, hn, true, false);
        CBind* bp = fs.binds.data + bi;
        bp.is_cell = true;
        ch_op_u16(ch, OP_NEWCELL_UNDEF, bp.slot);
    }
    co.next_is_derived_ctor = derived;
    FnTemplate* ct = compile_function_tmpl(co, ctor_fn, fields.data, fields.len, false);
    ct.is_class = true;
    ct.derived_ctor = derived;   // owes a super() call before it returns
    // a class prints as the whole class, not as its constructor
    ct.src_start = c.span.start;
    ct.src_end = c.span.end;
    ct.not_ctor = false;
    if c.name.len > 0 { tmpl_set_name(ct, c.name); }
    vec_push(&ch.subs, ct);
    ch_op_u16(ch, OP_CLOSURE, ch.subs.len - 1);

    i32 t_ctor = alloc_slot(fs);
    ch_op_u16(ch, OP_SETLOCAL, t_ctor);
    ch_op(ch, OP_POP);

    // Static blocks and static field initializers run with `this` bound to the
    // constructor; expose it as a class-scoped `this` (cellified when a nested
    // arrow closes over it).
    if has_static {
        i32 this_bind = declare(co, "this", true, false);
        CBind* tb = fs.binds.data + this_bind;
        if tb.is_cell { ch_op_u16(ch, OP_NEWCELL_UNDEF, tb.slot); }
        ch_op_u16(ch, OP_GETLOCAL, t_ctor);
        emit_init_binding(co, this_bind);
    }

    // static inheritance: derived ctor's [[Prototype]] is the parent ctor
    if derived {
        ch_op_u16(ch, OP_GETLOCAL, t_ctor);
        emit_load_name(co, "%super", c);
        ch_op(ch, OP_SETPROTO);
        ch_op(ch, OP_POP);
    }

    // C.prototype: fresh object chained to the parent's prototype
    ch_op(ch, OP_NEWOBJ);
    if derived {
        emit_load_name(co, "%super", c);
        ch_op_u16(ch, OP_GETPROP, name_const(co, "prototype"));
        ch_op(ch, OP_SETPROTO);
    }
    i32 t_proto = alloc_slot(fs);
    ch_op_u16(ch, OP_SETLOCAL, t_proto);
    ch_op_u16(ch, OP_GETLOCAL, t_ctor);
    ch_op_u16(ch, OP_DEFMETHOD, name_const(co, "constructor"));
    ch_op(ch, OP_POP);
    ch_op_u16(ch, OP_GETLOCAL, t_ctor);
    ch_op_u16(ch, OP_GETLOCAL, t_proto);
    // .prototype is a non-enumerable own property of the constructor
    ch_op_u16(ch, OP_DEFMETHOD, name_const(co, "prototype"));
    ch_op(ch, OP_POP);

    // The elements, in source order: every computed key is evaluated here,
    // once, and a method is defined as it is met. A field keeps its key for
    // the pass below, which runs the initializers once the methods are in
    // place.
    Vec<i32> key_slots = vec_new<i32>(4);
    for i32 i = 0; i < c.kids.len; i++ { vec_push(&key_slots, 0 - 1); }
    for i32 i = 0; i < c.kids.len; i++ {
        Node* m = *(c.kids.items + i);
        if m.kind == N_STATIC_BLOCK { continue; }
        if m.kind != N_CLASS_MEMBER || m == ctor_member { continue; }
        bool is_static = (m.flags & NF_STATIC) != 0;
        bool is_method = m.b != null && m.b.kind == N_FUNCTION
            && (m.b.flags & NF_METHOD) != 0;
        bool is_acc = (m.flags & (NF_GETTER | NF_SETTER)) != 0;
        bool computed = (m.flags & NF_COMPUTED) != 0;
        bool is_priv = m.a != null && m.a.kind == N_PRIVATE_IDENT;
        if member_is_private_method(m) {
            // the closure is made once and kept for the constructor to install
            infer_name(m.b, is_acc ? accessor_name(co, (m.flags & NF_GETTER) != 0 ? "get" : "set", m.a)
                                   : key_name_text(co, m.a));
            compile_function(co, m.b, false);
            i32 pi = find_local(fs, hidden_name(co, "%pm", vec_get(&elem_ix, i)));
            CBind pb = vec_get(&fs.binds, pi);
            ch_op_u16(ch, OP_SETCELL, pb.slot);
            ch_op(ch, OP_POP);
            continue;
        }
        if member_is_field(m) {
            // an instance field: the key now, the value in the constructor
            if computed {
                compile_expr(co, m.a);
                ch_op(ch, OP_TOPROPKEY);
                i32 bi = find_local(fs, hidden_name(co, "%fk", vec_get(&elem_ix, i)));
                CBind kb = vec_get(&fs.binds, bi);
                ch_op_u16(ch, OP_SETCELL, kb.slot);
                ch_op(ch, OP_POP);
            }
            continue;
        }
        if is_method && is_priv {
            // a static private method: the class is the only object with it
            ch_op_u16(ch, OP_GETLOCAL, t_ctor);
            infer_name(m.b, is_acc ? accessor_name(co, (m.flags & NF_GETTER) != 0 ? "get" : "set", m.a)
                                   : key_name_text(co, m.a));
            co.next_static_home = true;
            compile_function(co, m.b, false);
            emit_def_private(co, m);
            ch_op(ch, OP_POP);
            continue;
        }
        if is_method {
            ch_op_u16(ch, OP_GETLOCAL, is_static ? t_ctor : t_proto);
            if computed {
                compile_expr(co, m.a);
                ch_op(ch, OP_TOPROPKEY);
                co.next_static_home = is_static;
                compile_function(co, m.b, false);
                if is_acc {
                    i32 aop = (m.flags & NF_GETTER) != 0 ? OP_DEFGETTER_DYN : OP_DEFSETTER_DYN;
                    ch_op_u16(ch, aop, 0);   // class accessors are non-enumerable
                } else {
                    ch_op(ch, OP_DEFMETHOD_DYN);
                }
                ch_op(ch, OP_POP);
            } else if is_acc {
                str an = accessor_name(co, (m.flags & NF_GETTER) != 0 ? "get" : "set", m.a);
                if an.len > 0 { infer_name(m.b, an); }
                co.next_static_home = is_static;
                compile_function(co, m.b, false);
                i32 aop = (m.flags & NF_GETTER) != 0 ? OP_DEFGETTER : OP_DEFSETTER;
                ch_op_u16(ch, aop, prop_key_const(co, m.a));
                ch_u16(ch, 0);   // class accessors are non-enumerable
                ch_op(ch, OP_POP);
            } else {
                // the key names the method, as in an object literal
                infer_name(m.b, key_name_text(co, m.a));
                co.next_static_home = is_static;
                compile_function(co, m.b, false);
                ch_op_u16(ch, OP_DEFMETHOD, prop_key_const(co, m.a));
                ch_op(ch, OP_POP);
            }
            continue;
        }
        if is_static && computed {
            // a static field: the key now, the initializer below
            compile_expr(co, m.a);   // a computed key keeps the outer `this`
            ch_op(ch, OP_TOPROPKEY);
            i32 slot = alloc_slot(fs);
            ch_op_u16(ch, OP_SETLOCAL, slot);
            ch_op(ch, OP_POP);
            vec_set(&key_slots, i, slot);
        }
    }
    // Bind the inner class name to the freshly built constructor, so the
    // static initializers and any closure over it see the class value.
    if name_bind >= 0 {
        ch_op_u16(ch, OP_GETLOCAL, t_ctor);
        emit_init_binding(co, name_bind);
    }

    // Static field initializers and static blocks run after every method is
    // defined, in source order with each other.
    for i32 i = 0; i < c.kids.len; i++ {
        Node* m = *(c.kids.items + i);
        if m.kind == N_STATIC_BLOCK {
            bool saved_sb = co.in_static_block;
            i32 saved_floor = fs.loop_floor;
            bool saved_bt = co.static_this;
            co.static_this = true;
            co.in_static_block = true;
            bool saved_sh = fs.static_home;
            fs.static_home = true;
            fs.loop_floor = fs.loops.len;   // no break or continue leaves the block
            compile_stmt(co, m.a);
            fs.loop_floor = saved_floor;
            fs.static_home = saved_sh;
            co.in_static_block = saved_sb;
            co.static_this = saved_bt;
            continue;
        }
        if m == ctor_member || !member_is_static_field(m) { continue; }
        ch_op_u16(ch, OP_GETLOCAL, t_ctor);
        bool saved_st = co.static_this;
        bool saved_sh2 = fs.static_home;
        co.static_this = true;
        fs.static_home = true;   // an arrow here takes the class as its home
        if (m.flags & NF_COMPUTED) != 0 {
            ch_op_u16(ch, OP_GETLOCAL, vec_get(&key_slots, i));
            if m.b != null { compile_expr(co, m.b); } else { ch_op(ch, OP_UNDEF); }
            co.static_this = saved_st;
            fs.static_home = saved_sh2;
            ch_op_u16(ch, OP_DEFPROP_DYN, 1);   // an anonymous value takes the key as its name
        } else {
            infer_name(m.b, key_name_text(co, m.a));
            if m.b != null { compile_expr(co, m.b); } else { ch_op(ch, OP_UNDEF); }
            co.static_this = saved_st;
            fs.static_home = saved_sh2;
            if m.a != null && m.a.kind == N_PRIVATE_IDENT { emit_def_private(co, m); }
            else { ch_op_u16(ch, OP_DEFPROP, prop_key_const(co, m.a)); }
        }
        ch_op(ch, OP_POP);
    }
    vec_free(&key_slots);
    vec_free(&elem_ix);

    ch_op_u16(ch, OP_GETLOCAL, t_ctor);
    vec_free(&fields);
    fs.binds.len = saved_binds;
    fs.cur_slots = saved_slots;
    fs.depth--;
    co.strict = saved_strict;
    PrivScope done = vec_pop(&co.priv_scopes);
    vec_free(&done.names);
}

// --- statements ------------------------------------------------------------------------

private void inline_finallys(Compiler* co, i32 down_to) {
    FScope* fs = co.cur;
    i32 saved = fs.finallys.len;
    for i32 i = fs.finallys.len - 1; i >= down_to; i-- {
        FinEntry fe = vec_get(&fs.finallys, i);
        fs.finallys.len = i;
        if fe.fin != null {
            compile_stmt(co, fe.fin);
        } else {
            // leaving the loop's protected region, so its handler goes too;
            // the close is net zero on the stack, so a return value underneath
            // survives
            ch_op(&fs.ch, OP_TRY_POP);
            ch_op_u16(&fs.ch, OP_GETLOCAL, fe.iter_slot);
            ch_op_u16(&fs.ch, OP_ITER_CLOSE, fe.done_slot);
        }
    }
    fs.finallys.len = saved;
}

// Named evaluation: an anonymous function or class assigned to a name
// takes that name (const f = () => {} → f.name === "f").
private void infer_name(Node* init, str name) {
    if init == null || name.len == 0 { return; }
    if (init.kind == N_FUNCTION || init.kind == N_CLASS) && init.name.len == 0 {
        init.name = name;
        init.flags = init.flags | NF_NAME_INFERRED;
    }
}

private void compile_var_stmt(Compiler* co, Node* n) {
    bool lexical = (n.flags & (NF_LET | NF_CONST)) != 0;
    for i32 i = 0; i < n.kids.len; i++ {
        Node* d = *(n.kids.items + i);
        if d.a.kind == N_IDENT {
            i32 li = find_local(co.cur, d.a.name);
            if li < 0 {
                cerror(co, d, "unresolved declaration");
                continue;
            }
            if d.b != null {
                infer_name(d.b, d.a.name);
                compile_expr(co, d.b);
                emit_init_binding(co, li);
            } else if lexical {
                if (n.flags & NF_CONST) != 0 {
                    cerror(co, d, "const declaration needs an initializer");
                }
                ch_op(&co.cur.ch, OP_UNDEF);
                emit_init_binding(co, li);
            }
            continue;
        }
        // pattern declarator
        if d.b == null {
            cerror(co, d, "destructuring declaration needs an initializer");
            continue;
        }
        compile_expr(co, d.b);
        compile_destructure(co, d.a, true);
    }
}

// Lexical declarations hoist to the top of their scope as TDZ holes. Split out
// because a switch's case block is a single scope spanning every clause, so it
// feeds each clause's statements through here before compiling any of them.
private void hoist_lexical_decls(Compiler* co, NodeList* list, Vec<str>* vnames) {
    for i32 i = 0; i < list.len; i++ {
        Node* s = *(list.items + i);
        if s.kind == N_VAR && (s.flags & (NF_LET | NF_CONST)) != 0 {
            for i32 j = 0; j < s.kids.len; j++ {
                Node* d = *(s.kids.items + j);
                check_lexical_vs_var(co, d.a, vnames);
                declare_pattern(co, d.a, (s.flags & NF_CONST) != 0 ? 1 : 0);
            }
        }
        if s.kind == N_CLASS && s.name.len > 0 {
            if names_has(vnames, s.name) { redeclared(co, s, s.name); }
            declare_lexical(co, s, s.name, false);
        }
    }
}

// The function declaration a statement is, if it is one: labels on a
// declaration mean nothing to it.
private Node* function_decl_of(Node* s) {
    while s != null && s.kind == N_LABELED { s = s.a; }
    if s != null && s.kind == N_FUNCTION && s.name.len > 0 { return s; }
    return null;
}

// Function declarations bind before any statement runs. At the top of a
// function body they are var-like and may repeat; in a block they are
// lexical: no `var` of the same name in the block, and no second
// declaration, except that sloppy code may repeat a plain function.
// `seen` carries the declarations across the clauses of a switch.
private void hoist_function_decls(Compiler* co, NodeList* list, Vec<str>* vnames, bool body, Vec<NodePtr>* seen) {
    for i32 i = 0; i < list.len; i++ {
        Node* f = function_decl_of(*(list.items + i));
        if f == null { continue; }
        if !body {
            if names_has(vnames, f.name) { redeclared(co, f, f.name); }
            for i32 j = 0; j < seen.len; j++ {
                Node* g = vec_get(seen, j);
                if !str_equal(g.name, f.name) { continue; }
                bool plain = ((f.flags | g.flags) & (NF_GENERATOR | NF_ASYNC)) == 0;
                if co.strict || !plain { redeclared(co, f, f.name); }
                break;
            }
            vec_push(seen, f);
        }
        declare_plain(co, f, f.name);
    }
}

// Block statement list with optional class-field injection after a
// leading super() call (constructors only).
private void compile_block_stmts_ex(Compiler* co, NodeList* list, Node** fields, i32 n_fields) {
    FScope* fs = co.cur;
    fs.depth++;
    i32 saved_binds = fs.binds.len;
    i32 saved_slots = fs.cur_slots;

    // the `var` names this scope binds, which no lexical name here may
    // repeat, along with the parameters of the function whose body this is
    // or the catch parameter the block belongs to
    bool body = co.outer_is_body;
    Vec<str> vnames = vec_new<str>(4);
    for i32 i = 0; i < co.outer_names.len; i++ { vec_push(&vnames, vec_get(&co.outer_names, i)); }
    co.outer_names.len = 0;
    co.outer_is_body = false;
    for i32 i = 0; i < list.len; i++ {
        collect_var_names(*(list.items + i), &vnames);
    }
    hoist_lexical_decls(co, list, &vnames);
    Vec<NodePtr> seen = vec_new<NodePtr>(4);
    hoist_function_decls(co, list, &vnames, body, &seen);
    vec_free(&seen);
    vec_free(&vnames);
    for i32 i = 0; i < list.len; i++ {
        Node* f = function_decl_of(*(list.items + i));
        if f != null {
            i32 li = find_local(fs, f.name);
            compile_function(co, f, false);
            emit_init_binding(co, li);
        }
    }

    bool injected = n_fields == 0;
    for i32 i = 0; i < list.len; i++ {
        Node* s = *(list.items + i);
        if function_decl_of(s) != null { continue; }
        if !injected {
            bool first_is_super = i == 0 && s.kind == N_EXPR_STMT && s.a != null
                && s.a.kind == N_CALL && s.a.a != null && s.a.a.kind == N_SUPER;
            if first_is_super {
                compile_stmt(co, s);
                emit_field_inits(co, fields, n_fields);
                injected = true;
                continue;
            }
            emit_field_inits(co, fields, n_fields);
            injected = true;
        }
        compile_stmt(co, s);
    }
    if !injected {
        emit_field_inits(co, fields, n_fields);
    }

    fs.binds.len = saved_binds;
    fs.cur_slots = saved_slots;
    fs.depth--;
}

private void compile_block_stmts(Compiler* co, NodeList* list) {
    compile_block_stmts_ex(co, list, null, 0);
}

private void emit_field_inits(Compiler* co, Node** fields, i32 n_fields) {
    Chunk* ch = &co.cur.ch;
    for i32 i = 0; i < n_fields; i++ {
        Node* m = *(fields + i);
        ch_op(ch, OP_THIS);
        if member_is_private_method(m) {
            // the closure the class made, installed on this object alone
            emit_load_name(co, hidden_name(co, "%pm", i), m);
            emit_def_private(co, m);
            ch_op(ch, OP_POP);
            continue;
        }
        if (m.flags & NF_COMPUTED) != 0 {
            // the key was evaluated when the class was defined
            emit_load_name(co, hidden_name(co, "%fk", i), m);
            if m.b != null { compile_expr(co, m.b); } else { ch_op(ch, OP_UNDEF); }
            ch_op_u16(ch, OP_DEFPROP_DYN, 1);   // defined, so no setter runs
        } else if m.a != null && m.a.kind == N_PRIVATE_IDENT {
            infer_name(m.b, key_name_text(co, m.a));
            if m.b != null { compile_expr(co, m.b); } else { ch_op(ch, OP_UNDEF); }
            emit_def_private(co, m);
        } else {
            infer_name(m.b, key_name_text(co, m.a));
            if m.b != null { compile_expr(co, m.b); } else { ch_op(ch, OP_UNDEF); }
            ch_op_u16(ch, OP_DEFPROP, prop_key_const(co, m.a));
        }
        ch_op(ch, OP_POP);
    }
}

// Patches every jump aimed at loop_id to target, removing them.
private void patch_jumps(Compiler* co, Vec<BrkJump>* jumps, i32 loop_id, i32 target) {
    Chunk* ch = &co.cur.ch;
    i32 w = 0;
    for i32 i = 0; i < jumps.len; i++ {
        BrkJump bj = vec_get(jumps, i);
        if bj.loop_id == loop_id {
            ch_patch_to(ch, bj.at, target);
        } else {
            vec_set(jumps, w, bj);
            w++;
        }
    }
    jumps.len = w;
}

private LoopCtx make_loop_ctx(Compiler* co, bool is_loop) {
    FScope* fs = co.cur;
    LoopCtx lc;
    lc.is_loop = is_loop;
    lc.label = take_label(co);
    lc.id = fs.loop_id_counter;
    fs.loop_id_counter++;
    lc.fin_depth = fs.finallys.len;
    return lc;
}

// for-in over own enumerable keys (index-based over a keys snapshot).
private void compile_for_in(Compiler* co, Node* n) {
    FScope* fs = co.cur;
    Chunk* ch = &fs.ch;

    fs.depth++;
    i32 saved_binds = fs.binds.len;
    i32 saved_slots = fs.cur_slots;

    compile_expr(co, n.b);
    i32 jskip = ch_jump(ch, OP_JUMP_NULLISH);
    ch_op(ch, OP_KEYS);
    i32 t_obj = alloc_slot(fs);
    ch_op_u16(ch, OP_SETLOCAL, t_obj);
    ch_op(ch, OP_POP);
    i32 t_idx = alloc_slot(fs);
    ch_op_u16(ch, OP_CONST, ch_add_const(ch, value_int(0)));
    ch_op_u16(ch, OP_SETLOCAL, t_idx);
    ch_op(ch, OP_POP);
    i32 t_len = alloc_slot(fs);
    ch_op_u16(ch, OP_GETLOCAL, t_obj);
    ch_op_u16(ch, OP_GETPROP, name_const(co, "length"));
    ch_op_u16(ch, OP_SETLOCAL, t_len);
    ch_op(ch, OP_POP);

    i32 bind_start = fs.binds.len;
    Node* pattern = null;
    if n.a.kind == N_VAR {
        pattern = (*(n.a.kids.items)).a;
        declare_pattern(co, pattern, (n.a.flags & NF_CONST) != 0 ? 4 : 2);
    }
    i32 bind_end = fs.binds.len;

    LoopCtx lc = make_loop_ctx(co, true);
    i32 lcond = ch_pos(ch);
    ch_op_u16(ch, OP_GETLOCAL, t_idx);
    ch_op_u16(ch, OP_GETLOCAL, t_len);
    ch_op(ch, OP_LT);
    i32 jend = ch_jump(ch, OP_JUMPF);

    for i32 i = bind_start; i < bind_end; i++ {
        CBind b = vec_get(&fs.binds, i);
        if b.is_cell { ch_op_u16(ch, OP_NEWCELL_HOLE, b.slot); }
    }
    ch_op_u16(ch, OP_GETLOCAL, t_obj);
    ch_op_u16(ch, OP_GETLOCAL, t_idx);
    ch_op(ch, OP_GETINDEX);
    if pattern != null {
        compile_destructure(co, pattern, true);
    } else {
        compile_destructure(co, n.a, false);
    }

    vec_push(&fs.loops, lc);
    compile_stmt(co, n.c);
    ignore vec_pop(&fs.loops);

    i32 lcont = ch_pos(ch);
    patch_jumps(co, &fs.cont_jumps, lc.id, lcont);
    ch_op_u16(ch, OP_GETLOCAL, t_idx);
    ch_op_u16(ch, OP_CONST, ch_add_const(ch, value_int(1)));
    ch_op(ch, OP_ADD);
    ch_op_u16(ch, OP_SETLOCAL, t_idx);
    ch_op(ch, OP_POP);
    ch_op_u16(ch, OP_JUMP, lcond);
    ch_patch(ch, jend);
    ch_patch(ch, jskip);
    patch_jumps(co, &fs.break_jumps, lc.id, ch_pos(ch));

    fs.binds.len = saved_binds;
    fs.cur_slots = saved_slots;
    fs.depth--;
}

// for-of via the iterator protocol.
// `for await (x of e)`: desugars to a loop that awaits both iter.next()
// and each yielded value, so it works over async generators, sync
// iterables of promises, and plain sync iterables alike. The object's
// (sync) iterator is used — our generators return {value, done} directly,
// and awaiting a non-promise passes it through.
private void compile_for_await_of(Compiler* co, Node* n) {
    FScope* fs = co.cur;
    Chunk* ch = &fs.ch;

    fs.depth++;
    i32 saved_binds = fs.binds.len;
    i32 saved_slots = fs.cur_slots;

    compile_expr(co, n.b);
    ch_op(ch, OP_GET_AITER_W);       // [iter, wrapped]
    i32 t_wrapped = alloc_slot(fs);
    ch_op_u16(ch, OP_SETLOCAL, t_wrapped);
    ch_op(ch, OP_POP);
    i32 t_iter = alloc_slot(fs);
    ch_op_u16(ch, OP_SETLOCAL, t_iter);
    ch_op(ch, OP_POP);
    // the next method is read once, as the language's iterator record has it
    i32 t_next = alloc_slot(fs);
    ch_op_u16(ch, OP_GETLOCAL, t_iter);
    ch_op_u16(ch, OP_GETPROP, name_const(co, "next"));
    ch_op_u16(ch, OP_SETLOCAL, t_next);
    ch_op(ch, OP_POP);
    // tracks exhaustion, so a loop left early still releases the iterator
    i32 t_done = alloc_slot(fs);
    ch_op(ch, OP_FALSE);
    ch_op_u16(ch, OP_SETLOCAL, t_done);
    ch_op(ch, OP_POP);

    i32 bind_start = fs.binds.len;
    Node* pattern = null;
    if n.a.kind == N_VAR {
        pattern = (*(n.a.kids.items)).a;
        declare_pattern(co, pattern, (n.a.flags & NF_CONST) != 0 ? 4 : 2);
    }
    i32 bind_end = fs.binds.len;

    // Same cleanup shape as the synchronous loop: a return or an outward
    // break/continue closes through the pending-finally list, a throw closes
    // through the handler below, and this loop's own break closes at the exit.
    vec_push(&fs.finallys, FinEntry{ .fin = null, .iter_slot = t_iter, .done_slot = t_done });
    i32 jclose = ch_jump(ch, OP_TRY_PUSH);
    LoopCtx lc = make_loop_ctx(co, true);
    i32 lcond = ch_pos(ch);
    // result = await next.call(iter)
    ch_op_u16(ch, OP_GETLOCAL, t_next);
    ch_op_u16(ch, OP_GETLOCAL, t_iter);
    ch_op_u16(ch, OP_CALL, 0);
    ch_op(ch, OP_AWAIT);
    ch_op(ch, OP_ITER_CHECK);
    // if result.done: break (leaving result on the stack for the pop)
    ch_op(ch, OP_DUP);
    ch_op_u16(ch, OP_GETPROP, name_const(co, "done"));
    ch_op(ch, OP_DUP);
    ch_op_u16(ch, OP_SETLOCAL, t_done);
    ch_op(ch, OP_POP);
    i32 jend = ch_jump(ch, OP_JUMPT);
    // value = result.value, awaited when the iterator is a wrapped sync one
    ch_op_u16(ch, OP_GETPROP, name_const(co, "value"));
    emit_await_if_wrapped(co, t_wrapped);

    for i32 i = bind_start; i < bind_end; i++ {
        CBind b = vec_get(&fs.binds, i);
        if b.is_cell { ch_op_u16(ch, OP_NEWCELL_HOLE, b.slot); }
    }
    if pattern != null { compile_destructure(co, pattern, true); }
    else { compile_destructure(co, n.a, false); }

    vec_push(&fs.loops, lc);
    compile_stmt(co, n.c);
    ignore vec_pop(&fs.loops);

    i32 lcont = ch_pos(ch);
    patch_jumps(co, &fs.cont_jumps, lc.id, lcont);
    ch_op_u16(ch, OP_JUMP, lcond);
    ch_patch(ch, jend);
    ch_op(ch, OP_POP);             // drop the result object under done
    patch_jumps(co, &fs.break_jumps, lc.id, ch_pos(ch));
    ignore vec_pop(&fs.finallys);
    ch_op(ch, OP_TRY_POP);
    ch_op_u16(ch, OP_GETLOCAL, t_iter);
    ch_op_u16(ch, OP_ITER_CLOSE, t_done);
    i32 jdone = ch_jump(ch, OP_JUMP);
    ch_patch(ch, jclose);
    // the thrown value is on the stack; close, then let it carry on
    ch_op_u16(ch, OP_GETLOCAL, t_iter);
    ch_op_u16(ch, OP_ITER_CLOSE_ABRUPT, t_done);
    ch_op(ch, OP_RETHROW);
    ch_patch(ch, jdone);

    fs.binds.len = saved_binds;
    fs.cur_slots = saved_slots;
    fs.depth--;
}

private void compile_for_of(Compiler* co, Node* n) {
    FScope* fs = co.cur;
    Chunk* ch = &fs.ch;

    fs.depth++;
    i32 saved_binds = fs.binds.len;
    i32 saved_slots = fs.cur_slots;

    compile_expr(co, n.b);
    ch_op(ch, OP_GET_ITER);
    i32 t_iter = alloc_slot(fs);
    ch_op_u16(ch, OP_SETLOCAL, t_iter);
    ch_op(ch, OP_POP);
    // tracks exhaustion, so a loop left early still releases the iterator
    i32 t_done = alloc_slot(fs);
    ch_op(ch, OP_FALSE);
    ch_op_u16(ch, OP_SETLOCAL, t_done);
    ch_op(ch, OP_POP);

    i32 bind_start = fs.binds.len;
    Node* pattern = null;
    if n.a.kind == N_VAR {
        pattern = (*(n.a.kids.items)).a;
        declare_pattern(co, pattern, (n.a.flags & NF_CONST) != 0 ? 4 : 2);
    }
    i32 bind_end = fs.binds.len;

    // A `return`, or a break/continue aimed at an enclosing loop, leaves without
    // reaching the close below, so it is registered as pending cleanup. Pushed
    // before the loop context, so this loop's own break does not double-close.
    vec_push(&fs.finallys, FinEntry{ .fin = null, .iter_slot = t_iter, .done_slot = t_done });
    // and a throw out of the body unwinds here, closing before it propagates
    i32 jclose = ch_jump(ch, OP_TRY_PUSH);
    LoopCtx lc = make_loop_ctx(co, true);
    i32 lcond = ch_pos(ch);
    ch_op_u16(ch, OP_GETLOCAL, t_iter);
    ch_op(ch, OP_ITER_NEXT);       // [value, done]
    ch_op(ch, OP_DUP);
    ch_op_u16(ch, OP_SETLOCAL, t_done);
    ch_op(ch, OP_POP);
    i32 jend = ch_jump(ch, OP_JUMPT);

    for i32 i = bind_start; i < bind_end; i++ {
        CBind b = vec_get(&fs.binds, i);
        if b.is_cell { ch_op_u16(ch, OP_NEWCELL_HOLE, b.slot); }
    }
    // value is on the stack
    if pattern != null {
        compile_destructure(co, pattern, true);
    } else {
        compile_destructure(co, n.a, false);
    }

    vec_push(&fs.loops, lc);
    compile_stmt(co, n.c);
    ignore vec_pop(&fs.loops);

    i32 lcont = ch_pos(ch);
    patch_jumps(co, &fs.cont_jumps, lc.id, lcont);
    ch_op_u16(ch, OP_JUMP, lcond);
    ch_patch(ch, jend);
    ch_op(ch, OP_POP);             // drop the final value under done
    patch_jumps(co, &fs.break_jumps, lc.id, ch_pos(ch));
    ignore vec_pop(&fs.finallys);
    // leaving early (a break) closes the iterator; an exhausted one is left be
    ch_op(ch, OP_TRY_POP);
    ch_op_u16(ch, OP_GETLOCAL, t_iter);
    ch_op_u16(ch, OP_ITER_CLOSE, t_done);
    i32 jdone = ch_jump(ch, OP_JUMP);
    ch_patch(ch, jclose);
    // the thrown value is on the stack; close, then let it carry on
    ch_op_u16(ch, OP_GETLOCAL, t_iter);
    ch_op_u16(ch, OP_ITER_CLOSE_ABRUPT, t_done);
    ch_op(ch, OP_RETHROW);
    ch_patch(ch, jdone);

    fs.binds.len = saved_binds;
    fs.cur_slots = saved_slots;
    fs.depth--;
}

private void compile_stmt(Compiler* co, Node* n) {
    if n == null { return; }
    Chunk* ch = &co.cur.ch;
    FScope* fs = co.cur;
    i32 k = n.kind;
    emit_pos(co, n);   // source position for stack traces

    if k == N_EXPR_STMT {
        compile_expr(co, n.a);
        ch_op(ch, OP_POP);
        return;
    }
    if k == N_VAR { compile_var_stmt(co, n); return; }
    if k == N_BLOCK { compile_block_stmts(co, &n.kids); return; }
    if k == N_EMPTY { return; }
    if k == N_IF {
        compile_expr(co, n.a);
        i32 j1 = ch_jump(ch, OP_JUMPF);
        compile_stmt(co, n.b);
        if n.c != null {
            i32 j2 = ch_jump(ch, OP_JUMP);
            ch_patch(ch, j1);
            compile_stmt(co, n.c);
            ch_patch(ch, j2);
        } else {
            ch_patch(ch, j1);
        }
        return;
    }
    if k == N_WHILE {
        LoopCtx lc = make_loop_ctx(co, true);
        i32 lcond = ch_pos(ch);
        compile_expr(co, n.a);
        i32 jend = ch_jump(ch, OP_JUMPF);
        vec_push(&fs.loops, lc);
        compile_stmt(co, n.b);
        ignore vec_pop(&fs.loops);
        patch_jumps(co, &fs.cont_jumps, lc.id, lcond);
        ch_op_u16(ch, OP_JUMP, lcond);
        ch_patch(ch, jend);
        patch_jumps(co, &fs.break_jumps, lc.id, ch_pos(ch));
        return;
    }
    if k == N_DO_WHILE {
        LoopCtx lc = make_loop_ctx(co, true);
        i32 lstart = ch_pos(ch);
        vec_push(&fs.loops, lc);
        compile_stmt(co, n.a);
        ignore vec_pop(&fs.loops);
        i32 lcond = ch_pos(ch);
        patch_jumps(co, &fs.cont_jumps, lc.id, lcond);
        compile_expr(co, n.b);
        ch_op_u16(ch, OP_JUMPT, lstart);
        patch_jumps(co, &fs.break_jumps, lc.id, ch_pos(ch));
        return;
    }
    if k == N_FOR {
        fs.depth++;
        i32 saved_binds = fs.binds.len;
        i32 saved_slots = fs.cur_slots;
        i32 bind_start = fs.binds.len;
        if n.a != null {
            if n.a.kind == N_VAR {
                if (n.a.flags & (NF_LET | NF_CONST)) != 0 {
                    for i32 j = 0; j < n.a.kids.len; j++ {
                        Node* d = *(n.a.kids.items + j);
                        declare_pattern(co, d.a, (n.a.flags & NF_CONST) != 0 ? 1 : 0);
                    }
                }
                compile_var_stmt(co, n.a);
            } else {
                compile_expr(co, n.a);
                ch_op(ch, OP_POP);
            }
        }
        i32 bind_end = fs.binds.len;
        LoopCtx lc = make_loop_ctx(co, true);
        i32 lcond = ch_pos(ch);
        i32 jend = -1;
        if n.b != null {
            compile_expr(co, n.b);
            jend = ch_jump(ch, OP_JUMPF);
        }
        vec_push(&fs.loops, lc);
        compile_stmt(co, n.d);
        ignore vec_pop(&fs.loops);
        i32 lcont = ch_pos(ch);
        patch_jumps(co, &fs.cont_jumps, lc.id, lcont);
        // per-iteration boxes for captured loop variables
        for i32 i = bind_start; i < bind_end; i++ {
            CBind b = vec_get(&fs.binds, i);
            if b.is_cell {
                ch_op_u16(ch, OP_GETCELL, b.slot);
                ch_op_u16(ch, OP_SETLOCAL, b.slot);
                ch_op(ch, OP_POP);
                ch_op_u16(ch, OP_CELLIFY, b.slot);
            }
        }
        if n.c != null {
            compile_expr(co, n.c);
            ch_op(ch, OP_POP);
        }
        ch_op_u16(ch, OP_JUMP, lcond);
        if jend >= 0 { ch_patch(ch, jend); }
        patch_jumps(co, &fs.break_jumps, lc.id, ch_pos(ch));
        fs.binds.len = saved_binds;
        fs.cur_slots = saved_slots;
        fs.depth--;
        return;
    }
    if k == N_FOR_OF {
        if (n.flags & NF_AWAIT) != 0 {
            if !fs.is_async {
                cerror(co, n, "for await is only valid in async functions");
                return;
            }
            compile_for_await_of(co, n);
            return;
        }
        compile_for_of(co, n);
        return;
    }
    if k == N_FOR_IN {
        compile_for_in(co, n);
        return;
    }
    if k == N_BREAK || k == N_CONTINUE {
        i32 li = -1;
        if n.name.len > 0 {
            for i32 i = fs.loops.len - 1; i >= fs.loop_floor; i-- {
                LoopCtx c = vec_get(&fs.loops, i);
                if c.label.len > 0 && str_equal(c.label, n.name) {
                    li = i;
                    break;
                }
            }
            if li < 0 {
                cerror(co, n, "unknown label");
                return;
            }
            if k == N_CONTINUE {
                LoopCtx c = vec_get(&fs.loops, li);
                if !c.is_loop {
                    cerror(co, n, "continue target is not a loop");
                    return;
                }
            }
        } else {
            if fs.loops.len <= fs.loop_floor {
                cerror(co, n, "break/continue outside a loop");
                return;
            }
            li = fs.loops.len - 1;
            if k == N_CONTINUE {
                while li >= fs.loop_floor {
                    LoopCtx c = vec_get(&fs.loops, li);
                    if c.is_loop { break; }
                    li--;
                }
                if li < fs.loop_floor {
                    cerror(co, n, "continue outside a loop");
                    return;
                }
            }
        }
        LoopCtx lc = vec_get(&fs.loops, li);
        inline_finallys(co, lc.fin_depth);
        i32 j = ch_jump(ch, OP_JUMP);
        BrkJump bj;
        bj.at = j;
        bj.loop_id = lc.id;
        if k == N_BREAK {
            vec_push(&fs.break_jumps, bj);
        } else {
            vec_push(&fs.cont_jumps, bj);
        }
        return;
    }
    if k == N_RETURN {
        if fs.parent == null || co.in_static_block {
            cerror(co, n, "return outside a function");
            return;
        }
        if n.a != null {
            compile_expr(co, n.a);
        } else {
            ch_op(ch, OP_UNDEF);
        }
        inline_finallys(co, 0);
        ch_op(ch, OP_RETURN);
        return;
    }
    if k == N_THROW {
        compile_expr(co, n.a);
        ch_op(ch, OP_THROW);
        return;
    }
    if k == N_TRY {
        Node* fin = null;
        if n.c != null { fin = n.c; }
        if fin != null { vec_push(&fs.finallys, FinEntry{ .fin = fin, .iter_slot = 0, .done_slot = 0 }); }
        i32 jtry = ch_jump(ch, OP_TRY_PUSH);
        compile_stmt(co, n.a);
        ch_op(ch, OP_TRY_POP);
        if fin != null {
            ignore vec_pop(&fs.finallys);
            compile_stmt(co, fin);
        }
        i32 jend = ch_jump(ch, OP_JUMP);
        ch_patch(ch, jtry);
        if n.b != null {
            Node* cat = n.b;
            i32 jfin = -1;
            if fin != null {
                jfin = ch_jump(ch, OP_TRY_PUSH);
                vec_push(&fs.finallys, FinEntry{ .fin = fin, .iter_slot = 0, .done_slot = 0 });
            }
            // after the finally's TRY_PUSH, so a declined return completion
            // still unwinds through this try's finally
            ch_op(ch, OP_CATCH_ENTER);
            fs.depth++;
            i32 saved_binds = fs.binds.len;
            i32 saved_slots = fs.cur_slots;
            if cat.a != null {
                declare_pattern(co, cat.a, 2);
                compile_destructure(co, cat.a, true);
                co.outer_names.len = 0;
                collect_pattern_names(cat.a, &co.outer_names);
                co.outer_is_body = false;
            } else {
                ch_op(ch, OP_POP);
            }
            compile_stmt(co, cat.b);
            fs.binds.len = saved_binds;
            fs.cur_slots = saved_slots;
            fs.depth--;
            if fin != null {
                ignore vec_pop(&fs.finallys);
                ch_op(ch, OP_TRY_POP);
                compile_stmt(co, fin);
                i32 jend2 = ch_jump(ch, OP_JUMP);
                ch_patch(ch, jfin);
                compile_stmt(co, fin);
                ch_op(ch, OP_RETHROW);
                ch_patch(ch, jend2);
            }
        } else {
            compile_stmt(co, fin);
            ch_op(ch, OP_RETHROW);
        }
        ch_patch(ch, jend);
        return;
    }
    if k == N_SWITCH {
        compile_expr(co, n.a);
        i32 tmp = alloc_slot(fs);
        ch_op_u16(ch, OP_SETLOCAL, tmp);
        ch_op(ch, OP_POP);
        // Every clause shares one scope. It is opened before the clause
        // comparisons, because the jump table branches straight into a body
        // and would otherwise skip the code that puts the bindings in TDZ.
        fs.depth++;
        i32 saved_binds = fs.binds.len;
        i32 saved_slots = fs.cur_slots;
        Vec<str> svars = vec_new<str>(4);
        for i32 i = 0; i < n.kids.len; i++ {
            NodeList* cl = &(*(n.kids.items + i)).kids;
            for i32 s = 0; s < cl.len; s++ { collect_var_names(*(cl.items + s), &svars); }
        }
        for i32 i = 0; i < n.kids.len; i++ {
            hoist_lexical_decls(co, &(*(n.kids.items + i)).kids, &svars);
        }
        Vec<NodePtr> seen = vec_new<NodePtr>(4);
        for i32 i = 0; i < n.kids.len; i++ {
            hoist_function_decls(co, &(*(n.kids.items + i)).kids, &svars, false, &seen);
        }
        vec_free(&seen);
        vec_free(&svars);
        for i32 i = 0; i < n.kids.len; i++ {
            NodeList* cl = &(*(n.kids.items + i)).kids;
            for i32 s = 0; s < cl.len; s++ {
                Node* st = function_decl_of(*(cl.items + s));
                if st != null {
                    i32 li = find_local(fs, st.name);
                    compile_function(co, st, false);
                    emit_init_binding(co, li);
                }
            }
        }
        Vec<i32> case_jumps = vec_new<i32>(8);
        i32 default_idx = -1;
        LoopCtx lc = make_loop_ctx(co, false);
        for i32 i = 0; i < n.kids.len; i++ {
            Node* c = *(n.kids.items + i);
            if c.a == null {
                default_idx = i;
                vec_push(&case_jumps, -1);
                continue;
            }
            ch_op_u16(ch, OP_GETLOCAL, tmp);
            compile_expr(co, c.a);
            ch_op(ch, OP_SEQ);
            vec_push(&case_jumps, ch_jump(ch, OP_JUMPT));
        }
        i32 jdefault = ch_jump(ch, OP_JUMP);
        vec_push(&fs.loops, lc);
        for i32 i = 0; i < n.kids.len; i++ {
            Node* c = *(n.kids.items + i);
            i32 j = vec_get(&case_jumps, i);
            if j >= 0 {
                ch_patch(ch, j);
            } else {
                ch_patch(ch, jdefault);
            }
            for i32 s = 0; s < c.kids.len; s++ {
                Node* st = *(c.kids.items + s);
                // already bound and initialized above
                if function_decl_of(st) != null { continue; }
                compile_stmt(co, st);
            }
        }
        if default_idx < 0 { ch_patch(ch, jdefault); }
        fs.binds.len = saved_binds;
        fs.cur_slots = saved_slots;
        fs.depth--;
        ignore vec_pop(&fs.loops);
        patch_jumps(co, &fs.break_jumps, lc.id, ch_pos(ch));
        fs.cur_slots--;
        vec_free(&case_jumps);
        return;
    }
    if k == N_LABELED {
        Node* body = n.a;
        i32 bk = body != null ? body.kind : N_EMPTY;
        if bk == N_WHILE || bk == N_DO_WHILE || bk == N_FOR || bk == N_FOR_OF
            || bk == N_FOR_IN || bk == N_SWITCH {
            co.pending_label = n.name;
            compile_stmt(co, body);
            co.pending_label.data = null;
            co.pending_label.len = 0;
            return;
        }
        LoopCtx lc = make_loop_ctx(co, false);
        lc.label = n.name;
        vec_push(&fs.loops, lc);
        compile_stmt(co, body);
        ignore vec_pop(&fs.loops);
        patch_jumps(co, &fs.break_jumps, lc.id, ch_pos(ch));
        return;
    }
    if k == N_FUNCTION {
        compile_function(co, n, true);
        ch_op(ch, OP_POP);
        return;
    }
    if k == N_CLASS {
        if n.name.len > 0 {
            i32 li = find_local(fs, n.name);
            compile_class_expr(co, n);
            if li >= 0 {
                emit_init_binding(co, li);
            } else {
                ch_op(ch, OP_POP);
            }
        } else {
            compile_class_expr(co, n);
            ch_op(ch, OP_POP);
        }
        return;
    }
    if k == N_DEBUGGER { return; }
    if k == N_IMPORT || k == N_EXPORT {
        cerror(co, n, "modules are not supported yet");
        return;
    }
    cerror(co, n, "statement not supported yet");
}

// --- entry ---------------------------------------------------------------------------------

// The top level binds `this` the same way a function does, so an arrow
// written there captures it lexically. Without this an arrow at the top level
// has nothing to capture and falls back to reading the frame's receiver,
// which lets call/apply/bind supply one -- an arrow must never take one.
private void bind_toplevel_this(Compiler* co, FScope* fs) {
    if strmap_get<i32>(&fs.inner, "this") == null { return; }
    i32 bi = declare(co, "this", true, false);
    CBind b = vec_get(&fs.binds, bi);
    ch_op(&fs.ch, OP_THIS);
    ch_op_u16(&fs.ch, OP_SETLOCAL, b.slot);
    ch_op(&fs.ch, OP_POP);
    if b.is_cell { ch_op_u16(&fs.ch, OP_CELLIFY, b.slot); }
}

FnTemplate* compile_program(Compiler* co, Node* prog) {
    FScope fs;
    fscope_init(&fs, null, false);
    co.cur = &fs;
    co.strict = has_use_strict(&prog.kids);
    scan_inner(&fs.inner, prog, true);
    bind_toplevel_this(co, &fs);
    hoist_vars(co, prog);
    // a script's top level binds function declarations the way a function
    // body does, so one may repeat a `var` or another function
    co.outer_is_body = true;
    compile_block_stmts(co, &prog.kids);
    ch_op(&fs.ch, OP_UNDEF);
    ch_op(&fs.ch, OP_RETURN);
    str empty;
    empty.data = null;
    empty.len = 0;
    FnTemplate* t = chunk_finish(&fs.ch, empty, 0, fs.n_slots, false, false, false);
    t.src_name = co.src_name;
    t.sloppy = !co.strict;
    co.strict = false;
    co.cur = null;
    fscope_free(&fs);
    return t;
}

// Compiles a CommonJS module: the body as a 5-parameter function
// (exports, require, module, __dirname, __filename). The params are forced
// to cells so nested functions capture them; free names still resolve to
// globals. Called with those five arguments at require time.
FnTemplate* compile_cjs_module(Compiler* co, Node* prog) {
    FScope fs;
    fscope_init(&fs, null, false);
    co.cur = &fs;
    co.strict = has_use_strict(&prog.kids);
    scan_inner(&fs.inner, prog, true);
    str[5] pnames = { "exports", "require", "module", "__dirname", "__filename" };
    for i32 i = 0; i < 5; i++ { strmap_set<i32>(&fs.inner, pnames[i], 1); }
    Vec<i32> pslots = vec_new<i32>(5);
    for i32 i = 0; i < 5; i++ {
        i32 bi = declare(co, pnames[i], false, false);
        vec_push(&pslots, vec_get(&fs.binds, bi).slot);
    }
    for i32 i = 0; i < 5; i++ { ch_op_u16(&fs.ch, OP_CELLIFY, vec_get(&pslots, i)); }
    vec_free(&pslots);
    bind_toplevel_this(co, &fs);
    hoist_vars(co, prog);
    co.outer_is_body = true;   // as in a script, not a block
    compile_block_stmts(co, &prog.kids);
    ch_op(&fs.ch, OP_UNDEF);
    ch_op(&fs.ch, OP_RETURN);
    str empty;
    empty.data = null;
    empty.len = 0;
    FnTemplate* t = chunk_finish(&fs.ch, empty, 5, fs.n_slots, false, false, false);
    t.sloppy = !co.strict;
    co.strict = false;
    t.src_name = co.src_name;
    co.cur = null;
    fscope_free(&fs);
    return t;
}

// --- module compilation -----------------------------------------------------------

private bool node_has_source(Node* n) {
    return n.name.len > 0 || n.name.data != null;
}

// Registers a live import: the name reads slot_name.prop at each use.
private void register_import(Compiler* co, str slot_name, str spec, str prop, str local) {
    ModImport mi;
    mi.slot_name = slot_name;
    mi.prop = prop;
    mi.spec = spec;
    mi.has_msg = false;
    strmap_set<ModImport>(&co.mod_imports, local, mi);
}

// The message an import read throws with when the namespace has no such
// property: the module does not export the name, or has not run yet
// because the graph has a cycle. One string per import, shared by every
// read site.
private Value import_message(Compiler* co, ModImport* mi) {
    if !mi.has_msg {
        string s = format("cannot read import '{}' from '{}': not exported, or not yet initialized in a module cycle",
            mi.prop, mi.spec);
        str v = s;
        GcString* gs = gc_new_string(co.heap, v);
        free(s);
        mi.msg = value_cell(&gs.head);
        gc_root(co.heap, mi.msg);
        mi.has_msg = true;
    }
    return mi.msg;
}

// A "use strict" directive at the start of a body.
private bool has_use_strict(NodeList* list) {
    for i32 i = 0; i < list.len; i++ {
        Node* s = *(list.items + i);
        if s.kind != N_EXPR_STMT || s.a == null || s.a.kind != N_STRING { return false; }
        if str_equal(s.a.name, "use strict") { return true; }
    }
    return false;
}

// `at` is where the export was written, for the duplicate report.
private void add_export_name(Compiler* co, str local, str exported, Node* at) {
    for i32 i = 0; i < co.export_names.len; i++ {
        if str_equal(vec_get(&co.export_names, i).exported, exported) {
            string m = format("Duplicate export of '{}'", exported);
            str mv = m;
            cerror(co, at, mv);
            free(m);
            break;
        }
    }
    ExportName e;
    e.exported = exported;
    i32* head = strmap_get<i32>(&co.export_heads, local);
    e.next = head != null ? *head : -1;
    vec_push(&co.export_names, e);
    strmap_set<i32>(&co.export_heads, local, co.export_names.len - 1);
}

// Fills the link table from the module's import and export statements.
// Runs once the imports are registered, so `export { x }` of an imported
// name is recorded as the re-export it is. Type-only entries have no
// binding and are left out.
private void collect_links(Compiler* co, Node* prog, ModLinks* links) {
    for i32 i = 0; i < prog.kids.len; i++ {
        Node* s = *(prog.kids.items + i);
        if (s.flags & NF_TYPE_ONLY) != 0 { continue; }
        if s.kind == N_IMPORT && node_has_source(s) {
            if s.a != null {
                LinkImport li;
                li.spec = s.name;
                li.name = "default";
                vec_push(&links.imports, li);
            }
            for i32 j = 0; j < s.kids.len; j++ {
                Node* sp = *(s.kids.items + j);
                if (sp.flags & NF_TYPE_ONLY) != 0 { continue; }
                LinkImport li;
                li.spec = s.name;
                li.name = sp.name;
                vec_push(&links.imports, li);
            }
            continue;
        }
        if s.kind != N_EXPORT { continue; }
        if node_has_source(s) {
            if (s.flags & NF_STAR) != 0 {
                if s.b != null { vec_push(&links.locals, s.b.name); }
                else { vec_push(&links.stars, s.name); }
            } else {
                for i32 j = 0; j < s.kids.len; j++ {
                    Node* sp = *(s.kids.items + j);
                    if (sp.flags & NF_TYPE_ONLY) != 0 { continue; }
                    LinkIndirect ie;
                    ie.exported = sp.a != null ? sp.a.name : sp.name;
                    ie.spec = s.name;
                    ie.name = sp.name;
                    vec_push(&links.indirect, ie);
                }
            }
            continue;
        }
        if s.a == null {
            for i32 j = 0; j < s.kids.len; j++ {
                Node* sp = *(s.kids.items + j);
                if (sp.flags & NF_TYPE_ONLY) != 0 { continue; }
                str exported = sp.a != null ? sp.a.name : sp.name;
                ModImport* mi = strmap_get<ModImport>(&co.mod_imports, sp.name);
                if mi != null {
                    LinkIndirect ie;
                    ie.exported = exported;
                    ie.spec = mi.spec;
                    ie.name = mi.prop;
                    vec_push(&links.indirect, ie);
                } else {
                    vec_push(&links.locals, exported);
                }
            }
            continue;
        }
        Node* d = s.a;
        if (s.flags & NF_DEFAULT) != 0 {
            vec_push(&links.locals, "default");
            continue;
        }
        if d.kind == N_VAR {
            Vec<str> names = vec_new<str>(4);
            for i32 j = 0; j < d.kids.len; j++ {
                collect_pattern_names((*(d.kids.items + j)).a, &names);
            }
            for i32 j = 0; j < names.len; j++ { vec_push(&links.locals, vec_get(&names, j)); }
            vec_free(&names);
        } else if (d.kind == N_FUNCTION || d.kind == N_CLASS) && d.name.len > 0 {
            vec_push(&links.locals, d.name);
        }
    }
}

// Records every local name the module exports, and under which names,
// before the bindings are declared: `declare` marks them from this table
// and stores to them are then mirrored into the namespace.
private void collect_exports(Compiler* co, Node* prog) {
    strmap_free<i32>(&co.export_heads);
    strmap_init<i32>(&co.export_heads);
    co.export_names.len = 0;
    for i32 i = 0; i < prog.kids.len; i++ {
        Node* s = *(prog.kids.items + i);
        if s.kind != N_EXPORT || node_has_source(s) { continue; }
        if s.a == null {
            for i32 j = 0; j < s.kids.len; j++ {
                Node* sp = *(s.kids.items + j);
                add_export_name(co, sp.name, sp.a != null ? sp.a.name : sp.name, sp);
            }
            continue;
        }
        Node* d = s.a;
        bool is_default = (s.flags & NF_DEFAULT) != 0;
        if d.kind == N_VAR {
            Vec<str> names = vec_new<str>(4);
            for i32 j = 0; j < d.kids.len; j++ {
                collect_pattern_names((*(d.kids.items + j)).a, &names);
            }
            for i32 j = 0; j < names.len; j++ {
                str nm = vec_get(&names, j);
                add_export_name(co, nm, nm, d);
            }
            vec_free(&names);
        } else if (d.kind == N_FUNCTION || d.kind == N_CLASS) && d.name.len > 0 {
            str exported = d.name;
            if is_default { exported = "default"; }
            add_export_name(co, d.name, exported, d);
        } else if is_default {
            // `export default <expression>`: the name is taken even though
            // no binding carries it
            add_export_name(co, "%default", "default", s);
        }
    }
}

// %ns.name = <local name value>. The namespace object is loaded by
// name (it is a captured cell).
private void mirror_export(Compiler* co, str ns_name, str name, str exported) {
    Chunk* ch = &co.cur.ch;
    emit_load_name(co, ns_name, null);
    emit_load_name(co, name, null);
    ch_op_u16(ch, OP_SETPROP, name_const(co, exported));
    ch_op(ch, OP_POP);
}


// True if `n` contains an `await` (or `for await`) that belongs to the
// module top level — i.e. not nested inside a function/arrow/method, which
// carry their own async context.
private bool node_has_tla(Node* n) {
    if n == null { return false; }
    if n.kind == N_FUNCTION { return false; }
    if n.kind == N_AWAIT { return true; }
    if n.kind == N_FOR_OF && (n.flags & NF_AWAIT) != 0 { return true; }
    if n.kind == N_CLASS {
        // class methods are functions; only the extends expression runs in
        // module scope
        return node_has_tla(n.a);
    }
    if node_has_tla(n.a) || node_has_tla(n.b) || node_has_tla(n.c) || node_has_tla(n.d) { return true; }
    for i32 i = 0; i < n.kids.len; i++ {
        if node_has_tla(*(n.kids.items + i)) { return true; }
    }
    return false;
}

// Compiles a module. out_specs receives the dependency specifiers in
// slot order (the evaluator passes namespaces in that order).
FnTemplate* compile_module(Compiler* co, Node* prog, Vec<str>* out_specs, ModLinks* links) {
    FScope fs;
    fscope_init(&fs, null, false);
    co.cur = &fs;
    scan_inner(&fs.inner, prog, true);

    // A module using top-level await compiles as an async function; its
    // body runs as a coroutine that the event loop drains.
    for i32 i = 0; i < prog.kids.len; i++ {
        if node_has_tla(*(prog.kids.items + i)) { fs.is_async = true; break; }
    }

    // 1. assign a dep slot per distinct specifier
    StrMap<i32> spec_slot;
    strmap_init<i32>(&spec_slot);
    for i32 i = 0; i < prog.kids.len; i++ {
        Node* s = *(prog.kids.items + i);
        bool has_src = (s.kind == N_IMPORT && node_has_source(s))
            || (s.kind == N_EXPORT && node_has_source(s));
        if !has_src { continue; }
        if strmap_get<i32>(&spec_slot, s.name) == null {
            i32 slot = out_specs.len;
            strmap_set<i32>(&spec_slot, s.name, slot);
            vec_push(out_specs, s.name);
        }
    }
    i32 n_deps = out_specs.len;

    // Interned "%ns" / "%modK" names living in the arena.
    str ns_name = hidden_name(co, "%ns", 0);
    co.ns_name = ns_name;
    co.in_module = true;
    co.strict = true;   // module code is strict-mode code
    collect_exports(co, prog);
    Vec<str> mod_names = vec_new<str>(4);
    for i32 i = 0; i < n_deps; i++ {
        vec_push(&mod_names, hidden_name(co, "%mod", i));
    }

    // 2. params: %ns then one per dependency. Force them to be cells so
    //    nested functions can capture them, and cellify the incoming
    //    argument values.
    strmap_set<i32>(&fs.inner, ns_name, 1);
    for i32 i = 0; i < n_deps; i++ {
        strmap_set<i32>(&fs.inner, vec_get(&mod_names, i), 1);
    }
    i32 ns_slot = declare(co, ns_name, true, false);
    Vec<i32> mod_slots = vec_new<i32>(4);
    for i32 i = 0; i < n_deps; i++ {
        i32 mi = declare(co, vec_get(&mod_names, i), true, false);
        vec_push(&mod_slots, vec_get(&fs.binds, mi).slot);
    }
    i32 n_params = 1 + n_deps;
    ch_op_u16(&fs.ch, OP_CELLIFY, vec_get(&fs.binds, ns_slot).slot);
    for i32 i = 0; i < n_deps; i++ {
        ch_op_u16(&fs.ch, OP_CELLIFY, vec_get(&mod_slots, i));
    }

    // after the parameter slots: declaring anything before them would shift
    // the dependency namespaces the evaluator passes in slot order
    bind_toplevel_this(co, &fs);

    strmap_free<ModImport>(&co.mod_imports);
    strmap_init<ModImport>(&co.mod_imports);

    // 3. import bindings: named/default are live (registered); namespace
    //    imports bind the whole object as a local.
    for i32 i = 0; i < prog.kids.len; i++ {
        Node* s = *(prog.kids.items + i);
        if s.kind != N_IMPORT { continue; }
        if !node_has_source(s) { continue; }
        i32* slotp = strmap_get<i32>(&spec_slot, s.name);
        if slotp == null { continue; }
        str slot_name = vec_get(&mod_names, *slotp);
        if s.a != null {
            register_import(co, slot_name, s.name, "default", s.a.name);
        }
        if s.b != null {
            i32 bi = declare(co, s.b.name, true, false);
            CBind b = vec_get(&fs.binds, bi);
            if b.is_cell { ch_op_u16(&fs.ch, OP_NEWCELL_UNDEF, b.slot); }
            emit_load_name(co, slot_name, null);
            emit_init_binding(co, bi);
        }
        for i32 j = 0; j < s.kids.len; j++ {
            Node* sp = *(s.kids.items + j);
            register_import(co, slot_name, s.name, sp.name, sp.a.name);
        }
    }

    if links != null { collect_links(co, prog, links); }

    // 4. hoist vars (unwrapping exports)
    for i32 i = 0; i < prog.kids.len; i++ {
        Node* s = *(prog.kids.items + i);
        Node* d = s.kind == N_EXPORT && s.a != null ? s.a : s;
        hoist_vars(co, d);
    }

    // 5. lexical/class TDZ holes at top level (before functions, whose
    //    bodies may reference them)
    for i32 i = 0; i < prog.kids.len; i++ {
        Node* s = *(prog.kids.items + i);
        Node* d = s.kind == N_EXPORT && s.a != null ? s.a : s;
        if d == null { continue; }
        if d.kind == N_VAR && (d.flags & (NF_LET | NF_CONST)) != 0 {
            for i32 j = 0; j < d.kids.len; j++ {
                declare_pattern(co, (*(d.kids.items + j)).a, (d.flags & NF_CONST) != 0 ? 1 : 0);
            }
        }
        if d.kind == N_CLASS && d.name.len > 0 {
            declare_lexical(co, d, d.name, false);
        }
    }

    // 6. top-level function declarations (hoisted); initializing an
    //    exported one writes it to the namespace.
    //
    //    A module's top level is lexical, unlike a script's: a function
    //    declared there may not repeat another declaration, nor a `var`.
    Vec<str> mod_vars = vec_new<str>(4);
    for i32 i = 0; i < prog.kids.len; i++ {
        Node* s = *(prog.kids.items + i);
        collect_var_names(s.kind == N_EXPORT && s.a != null ? s.a : s, &mod_vars);
    }
    Vec<NodePtr> mod_fns = vec_new<NodePtr>(4);
    for i32 i = 0; i < prog.kids.len; i++ {
        Node* s = *(prog.kids.items + i);
        Node* d = function_decl_of(s.kind == N_EXPORT && s.a != null ? s.a : s);
        if d == null { continue; }
        if names_has(&mod_vars, d.name) { redeclared(co, d, d.name); }
        for i32 j = 0; j < mod_fns.len; j++ {
            if str_equal(vec_get(&mod_fns, j).name, d.name) {
                redeclared(co, d, d.name);
                break;
            }
        }
        vec_push(&mod_fns, d);
        declare_plain(co, d, d.name);
    }
    vec_free(&mod_fns);
    vec_free(&mod_vars);
    for i32 i = 0; i < prog.kids.len; i++ {
        Node* s = *(prog.kids.items + i);
        Node* d = function_decl_of(s.kind == N_EXPORT && s.a != null ? s.a : s);
        if d != null {
            i32 li = find_local(&fs, d.name);
            compile_function(co, d, false);
            emit_init_binding(co, li);
        }
    }

    // 7. body
    for i32 i = 0; i < prog.kids.len; i++ {
        Node* s = *(prog.kids.items + i);
        if s.kind == N_IMPORT { continue; }
        if function_decl_of(s) != null { continue; }
        if s.kind == N_EXPORT && s.a != null && s.a.kind == N_FUNCTION
            && s.a.name.len > 0 { continue; }
        if s.kind == N_EXPORT {
            compile_export(co, s, ns_name, &spec_slot, &mod_names);
            continue;
        }
        compile_stmt(co, s);
    }

    ch_op(&fs.ch, OP_UNDEF);
    ch_op(&fs.ch, OP_RETURN);
    str empty;
    empty.data = null;
    empty.len = 0;
    FnTemplate* t = chunk_finish(&fs.ch, empty, n_params, fs.n_slots, false, false, fs.is_async);
    t.src_name = co.src_name;
    co.cur = null;
    co.in_module = false;
    co.strict = false;
    vec_free(&mod_slots);
    vec_free(&mod_names);
    strmap_free<i32>(&spec_slot);
    fscope_free(&fs);
    return t;
}

private void collect_pattern_names(Node* pat, Vec<str>* out) {
    if pat == null { return; }
    if pat.kind == N_IDENT {
        vec_push(out, pat.name);
        return;
    }
    if pat.kind == N_ASSIGN_PATTERN || pat.kind == N_REST {
        collect_pattern_names(pat.a, out);
        return;
    }
    if pat.kind == N_ARRAY_PATTERN {
        for i32 i = 0; i < pat.kids.len; i++ {
            collect_pattern_names(*(pat.kids.items + i), out);
        }
        return;
    }
    if pat.kind == N_OBJECT_PATTERN {
        for i32 i = 0; i < pat.kids.len; i++ {
            Node* pp = *(pat.kids.items + i);
            collect_pattern_names(pp.kind == N_REST ? pp.a : pp.b, out);
        }
        return;
    }
}

private void compile_export(Compiler* co, Node* s, str ns_name,
        StrMap<i32>* spec_slot, Vec<str>* mod_names) {
    Chunk* ch = &co.cur.ch;
    bool is_default = (s.flags & NF_DEFAULT) != 0;

    // export * from "m" / export { a as b } from "m"
    if node_has_source(s) {
        i32* slotp = strmap_get<i32>(spec_slot, s.name);
        if slotp == null { return; }
        str mname = vec_get(mod_names, *slotp);
        if (s.flags & NF_STAR) != 0 {
            emit_load_name(co, ns_name, null);
            emit_load_name(co, mname, null);
            if s.b != null {
                // export * as name from "m": the dependency namespace itself
                ch_op_u16(ch, OP_SETPROP, name_const(co, s.b.name));
            } else {
                ch_op(ch, OP_OBJ_SPREAD);
            }
            ch_op(ch, OP_POP);
            return;
        }
        for i32 i = 0; i < s.kids.len; i++ {
            Node* sp = *(s.kids.items + i);
            str exported = sp.a != null ? sp.a.name : sp.name;
            emit_load_name(co, ns_name, null);
            emit_load_name(co, mname, null);
            ch_op_u16(ch, OP_GETPROP, name_const(co, sp.name));
            ch_op_u16(ch, OP_SETPROP, name_const(co, exported));
            ch_op(ch, OP_POP);
        }
        return;
    }

    // export { a, b as c }: a module binding is already written through
    // at every store (and may not be initialized yet, if declared later);
    // an imported or global name is copied here
    if s.a == null {
        for i32 i = 0; i < s.kids.len; i++ {
            Node* sp = *(s.kids.items + i);
            i32 li = find_local(co.cur, sp.name);
            if li >= 0 && vec_get(&co.cur.binds, li).exported { continue; }
            str exported = sp.a != null ? sp.a.name : sp.name;
            mirror_export(co, ns_name, sp.name, exported);
        }
        return;
    }

    Node* d = s.a;
    if is_default {
        // export default class Name: a declaration, so the module can use
        // the name; initializing the binding writes it as `default`
        if d.kind == N_CLASS && d.name.len > 0 {
            i32 li = find_local(co.cur, d.name);
            if li >= 0 {
                compile_class_expr(co, d);
                emit_init_binding(co, li);
                return;
            }
        }
        // export default <expr | class-expr | function-expr>
        emit_load_name(co, ns_name, null);
        compile_expr(co, d);
        ch_op_u16(ch, OP_SETPROP, name_const(co, "default"));
        ch_op(ch, OP_POP);
        return;
    }

    // export var/let/const, export class: initializing the binding
    // writes it to the namespace (emit_init_binding). A `var` without an
    // initializer emits no store, so its name is copied here to make the
    // property exist.
    if d.kind == N_VAR {
        compile_var_stmt(co, d);
        if (d.flags & (NF_LET | NF_CONST)) == 0 {
            for i32 i = 0; i < d.kids.len; i++ {
                Node* dc = *(d.kids.items + i);
                if dc.b == null && dc.a.kind == N_IDENT {
                    mirror_export(co, ns_name, dc.a.name, dc.a.name);
                }
            }
        }
        return;
    }
    if d.kind == N_CLASS && d.name.len > 0 {
        i32 li = find_local(co.cur, d.name);
        compile_class_expr(co, d);
        if li >= 0 { emit_init_binding(co, li); } else { ch_op(ch, OP_POP); }
        return;
    }
    // interface/type-alias already stripped; anything else: compile as stmt
    compile_stmt(co, d);
}

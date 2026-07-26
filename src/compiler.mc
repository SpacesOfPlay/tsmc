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
import bump;
import object;
import bigint;

struct CBind {
    str name;
    i32 slot;
    i32 depth;
    bool is_cell;
    bool is_const;
    bool tdz;
}

struct CUp {
    str name;
    bool is_const;
    bool tdz;
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
    Vec<BrkJump> break_jumps;
    Vec<BrkJump> cont_jumps;
    Vec<LoopCtx> loops;
    Vec<NodePtr> finallys;
    i32 loop_id_counter;
}

// A name imported into the current module: read live from a
// dependency namespace slot.
struct ModImport {
    str slot_name;   // "%modK"
    str prop;        // exported name in the source module
}

struct Compiler {
    DiagList* diags;
    GcHeap* heap;
    AtomTable* atoms;
    Bump* arena;
    FScope* cur;
    str pending_label;
    bool in_module;
    bool static_this;   // inside a static block / field: `this` is the class ctor
    StrMap<ModImport> mod_imports;   // valid while in_module
    str src;        // source text, for line/col of stack-trace positions
    str src_name;   // source filename
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
    co.static_this = false;
    strmap_init<ModImport>(&co.mod_imports);
    co.src.data = null;
    co.src.len = 0;
    co.src_name = "";
}

// Source text + filename for stack-trace positions.
void compiler_set_source(Compiler* co, str src, str src_name) {
    co.src = src;
    co.src_name = src_name;
}

private void cerror(Compiler* co, Node* n, str msg) {
    diag_add(co.diags, DIAG_ERROR, n.span, msg);
}

// Records the source position of a node at the current code offset.
private void emit_pos(Compiler* co, Node* n) {
    if co.src.data == null { return; }
    LineCol lc = diag_line_col(co.src, n.span.start);
    ch_record_pos(&co.cur.ch, lc.line, lc.col);
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
    vec_init<BrkJump>(&fs.break_jumps, 8);
    vec_init<BrkJump>(&fs.cont_jumps, 8);
    vec_init<LoopCtx>(&fs.loops, 4);
    vec_init<NodePtr>(&fs.finallys, 4);
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

// Private names are stored under "%#name": the '%' hides them from
// enumeration, the '#' keeps them clear of the engine's %-internals.
private i32 private_key_const(Compiler* co, str name) {
    string s = format("%#{}", name);
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
    if key.kind == N_PRIVATE_IDENT { return private_key_const(co, key.name); }
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
    // like a method body. Its computed key is likewise compiled in the
    // constructor. Treat both as inner-function code so the enclosing scope
    // cellifies anything they close over.
    if n.kind == N_CLASS_MEMBER && member_is_field(n) {
        scan_all_names(set, n.b);
        if (n.flags & NF_COMPUTED) != 0 { scan_all_names(set, n.a); }
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

private void declare_lexical(Compiler* co, str name, bool is_const) {
    FScope* fs = co.cur;
    i32 bi = declare(co, name, is_const, true);
    CBind b = vec_get(&fs.binds, bi);
    if b.is_cell {
        ch_op_u16(&fs.ch, OP_NEWCELL_HOLE, b.slot);
    } else {
        ch_op_u16(&fs.ch, OP_SETHOLE, b.slot);
    }
}

private void declare_plain(Compiler* co, str name) {
    FScope* fs = co.cur;
    i32 bi = declare(co, name, false, false);
    CBind b = vec_get(&fs.binds, bi);
    if b.is_cell {
        ch_op_u16(&fs.ch, OP_NEWCELL_UNDEF, b.slot);
    }
}

// Walks a binding pattern applying `mode` per name:
// 0 lexical let, 1 lexical const, 2 plain, 3 hoisted var.
private void declare_pattern(Compiler* co, Node* pat, i32 mode) {
    if pat == null { return; }
    i32 k = pat.kind;
    if k == N_IDENT {
        if mode == 0 { declare_lexical(co, pat.name, false); }
        if mode == 1 { declare_lexical(co, pat.name, true); }
        if mode == 2 { declare_plain(co, pat.name); }
        if mode == 3 { hoist_declare_var(co, pat); }
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
    i32 li = find_local(fs, id.name);
    if li >= 0 { return; }   // var redeclaration shares the binding
    i32 bi = declare(co, id.name, false, false);
    CBind b = vec_get(&fs.binds, bi);
    if b.is_cell {
        ch_op_u16(&fs.ch, OP_NEWCELL_UNDEF, b.slot);
    }
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
            ch_op_u16(&fs.ch, OP_GETPROP, name_const(co, mi.prop));
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

// Emits a store that keeps the value on the stack.
private void emit_store_ident(Compiler* co, Node* n) {
    FScope* fs = co.cur;
    i32 li = find_local(fs, n.name);
    if li >= 0 {
        CBind b = vec_get(&fs.binds, li);
        if b.is_const {
            cerror(co, n, "assignment to constant");
        }
        ch_op_u16(&fs.ch, b.is_cell ? OP_SETCELL : OP_SETLOCAL, b.slot);
        return;
    }
    i32 ui = resolve_upval(fs, n.name);
    if ui >= 0 {
        CUp u = vec_get(&fs.ups, ui);
        if u.is_const {
            cerror(co, n, "assignment to constant");
        }
        ch_op_u16(&fs.ch, OP_SETUPVAL, ui);
        return;
    }
    if co.in_module && strmap_get<ModImport>(&co.mod_imports, n.name) != null {
        cerror(co, n, "cannot assign to an imported binding");
        return;
    }
    ch_op_u16(&fs.ch, OP_SETGLOBAL, name_const(co, n.name));
}

// Direct store for initialization; bypasses the const check.
private void emit_init_binding(Compiler* co, i32 bind_idx) {
    FScope* fs = co.cur;
    CBind b = vec_get(&fs.binds, bind_idx);
    ch_op_u16(&fs.ch, b.is_cell ? OP_SETCELL : OP_SETLOCAL, b.slot);
    ch_op(&fs.ch, OP_POP);
}

private bool super_available(Compiler* co) {
    str nm = "%super";
    if find_local(co.cur, nm) >= 0 { return true; }
    return resolve_upval(co.cur, nm) >= 0;
}

// --- destructuring ---------------------------------------------------------------

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
        if k == N_MEMBER && (pat.flags & (NF_OPT_CHAIN | NF_PRIVATE)) != 0 {
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
            ch_op_u16(ch, OP_SETPROP, name_const(co, pat.name));
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
                // literal, so the "rest comes last" rule is checked here
                if i != pat.kids.len - 1 {
                    cerror(co, e, "a rest element must be last");
                }
                ch_op_u16(ch, OP_GETLOCAL, t_iter);
                ch_op_u16(ch, OP_ITER_REST, t_done);
                compile_destructure(co, e.a, declare_mode);
                exhausted = true;
                break;
            }
            ch_op_u16(ch, OP_GETLOCAL, t_iter);
            ch_op_u16(ch, OP_ITER_STEP, t_done);
            compile_destructure(co, e, declare_mode);
        }
        // a pattern that stopped early releases the iterator
        if !exhausted {
            ch_op_u16(ch, OP_GETLOCAL, t_iter);
            ch_op_u16(ch, OP_ITER_CLOSE, t_done);
        }
        co.cur.cur_slots -= 2;
        return;
    }
    if k == N_OBJECT_PATTERN || (!declare_mode && k == N_OBJECT) {
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
            if (pp.flags & NF_COMPUTED) != 0 {
                ch_op_u16(ch, OP_GETLOCAL, tmp);
                compile_expr(co, keyn);
                ch_op(ch, OP_GETINDEX);
            } else {
                ch_op_u16(ch, OP_GETLOCAL, tmp);
                ch_op_u16(ch, OP_GETPROP, prop_key_const(co, keyn));
                if keyn.kind != N_NUMBER {
                    u32 a2 = atom_intern(co.atoms, keyn.name);
                    vec_push(&taken, cast(i32, a2));
                }
            }
            compile_destructure(co, target, declare_mode);
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
                ch_op_u16(ch, OP_SETPROP, private_key_const(co, t.name));
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
            i32 kc = (t.flags & NF_PRIVATE) != 0
                ? private_key_const(co, t.name) : name_const(co, t.name);
            i32 t_obj = alloc_slot(co.cur);
            compile_expr(co, t.a);
            ch_op_u16(ch, OP_SETLOCAL, t_obj);
            ch_op(ch, OP_POP);
            ch_op_u16(ch, OP_GETLOCAL, t_obj);
            ch_op_u16(ch, OP_GETPROP, kc);
            i32 j = ch_jump(ch, jop);
            ch_op_u16(ch, OP_GETLOCAL, t_obj);
            compile_expr(co, n.b);
            ch_op_u16(ch, OP_SETPROP, kc);
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
        i32 kc = (t.flags & NF_PRIVATE) != 0 ? private_key_const(co, t.name) : name_const(co, t.name);
        compile_expr(co, t.a);
        ch_op(ch, OP_DUP);
        ch_op_u16(ch, OP_GETPROP, kc);
        compile_expr(co, n.b);
        ch_op(ch, op);
        ch_op_u16(ch, OP_SETPROP, kc);
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
        if t.kind == N_MEMBER {
            mkc = (t.flags & NF_PRIVATE) != 0 ? private_key_const(co, t.name) : name_const(co, t.name);
            compile_expr(co, t.a);
            ch_op(ch, OP_DUP);
            ch_op_u16(ch, OP_GETPROP, mkc);
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
            ch_op_u16(ch, OP_SETPROP, mkc);
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
        if n.kind == N_CALL && n.a != null
            && (n.a.kind == N_MEMBER || n.a.kind == N_INDEX)
            && (n.a.flags & NF_OPT_CHAIN) != 0 {
            return true;
        }
        n = n.a;
    }
    return false;
}

private void emit_chain(Compiler* co, Node* n, Vec<i32>* nils) {
    Chunk* ch = &co.cur.ch;
    i32 k = n.kind;
    if k == N_MEMBER && n.a.kind != N_SUPER {
        emit_chain(co, n.a, nils);
        if (n.flags & NF_OPT_CHAIN) != 0 {
            vec_push(nils, ch_jump(ch, OP_JUMP_NULLISH));
        }
        i32 mk = (n.flags & NF_PRIVATE) != 0
            ? private_key_const(co, n.name) : name_const(co, n.name);
        ch_op_u16(ch, OP_GETPROP, mk);
        return;
    }
    if k == N_INDEX {
        emit_chain(co, n.a, nils);
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
            emit_chain(co, callee.a, nils);
            if (callee.flags & NF_OPT_CHAIN) != 0 {
                vec_push(nils, ch_jump(ch, OP_JUMP_NULLISH));
            }
            i32 mk = (callee.flags & NF_PRIVATE) != 0
                ? private_key_const(co, callee.name) : name_const(co, callee.name);
            ch_op_u16(ch, OP_GETMETHOD, mk);
        } else if callee.kind == N_INDEX {
            emit_chain(co, callee.a, nils);
            if (callee.flags & NF_OPT_CHAIN) != 0 {
                vec_push(nils, ch_jump(ch, OP_JUMP_NULLISH));
            }
            compile_expr(co, callee.b);
            ch_op(ch, OP_GETMETHOD_DYN);
        } else {
            emit_chain(co, callee, nils);
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

private void compile_call(Compiler* co, Node* n) {
    Chunk* ch = &co.cur.ch;
    Node* callee = n.a;
    if callee.kind == N_IMPORT_EXPR {
        // dynamic import(spec): compile the specifier, then hand it and this
        // module's path to the runtime loader (OP_DYNIMPORT -> a promise).
        if n.kids.len < 1 {
            cerror(co, n, "import() requires exactly one argument");
            ch_op(ch, OP_UNDEF);
            return;
        }
        compile_expr(co, *(n.kids.items + 0));
        ch_op_u16(ch, OP_CONST, str_const(co, co.src_name));
        ch_op(ch, OP_DYNIMPORT);
        return;
    }
    if callee.kind == N_SUPER {
        if !super_available(co) {
            cerror(co, n, "super outside a derived class constructor");
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
        emit_load_name(co, "%super", n);
        ch_op_u16(ch, OP_GETPROP, name_const(co, "prototype"));
        if callee.kind == N_INDEX {
            compile_expr(co, callee.b);
            ch_op(ch, OP_GETINDEX);
        } else {
            ch_op_u16(ch, OP_GETPROP, name_const(co, callee.name));
        }
        // the receiver stays `this`, as for super.name(...)
        ch_op(ch, OP_THIS);
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
        i32 mk = (callee.flags & NF_PRIVATE) != 0
            ? private_key_const(co, callee.name) : name_const(co, callee.name);
        ch_op_u16(ch, OP_GETMETHOD, mk);
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
        bool ok;
        BigNum bn = bn_from_str(t, &ok);
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
        i32 src = str_const(co, n.name);
        i32 flags = str_const(co, n.aux);
        ch_op(ch, OP_REGEX);
        ch_u16(ch, src);
        ch_u16(ch, flags);
        return;
    }
    if k == N_IDENT { emit_load_ident(co, n); return; }
    if k == N_IMPORT_META {
        // import.meta: an object exposing `url` (a file:// URL of this module).
        ch_op(ch, OP_NEWOBJ);
        ch_op(ch, OP_DUP);
        ch_op_u16(ch, OP_CONST, import_meta_url_const(co));
        ch_op_u16(ch, OP_SETPROP, name_const(co, "url"));
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
        FScope* fs = co.cur;
        str nm = "this";
        if fs.is_arrow {
            if find_local(fs, nm) >= 0 || resolve_upval(fs, nm) >= 0 {
                emit_load_name(co, nm, n);
                return;
            }
        } else if co.static_this && find_local(fs, nm) >= 0 {
            // inline static block / field: `this` is the class-scoped binding
            emit_load_name(co, nm, n);
            return;
        }
        ch_op(ch, OP_THIS);
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
                ch_op(ch, OP_SETINDEX);
                ch_op(ch, OP_POP);
                continue;
            }
            if (p.flags & NF_SHORTHAND) != 0 && p.b != null {
                cerror(co, p, "shorthand initializer outside destructuring");
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
            ch_op_u16(ch, OP_SETPROP, prop_key_const(co, p.a));
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
        ch_op_u16(ch, OP_SETPROP, name_const(co, "raw"));
        ch_op(ch, OP_POP);
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
            ch_op_u16(ch, OP_HASPRIVATE, private_key_const(co, n.a.name));
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
            if t.kind == N_MEMBER && (t.flags & (NF_OPT_CHAIN | NF_PRIVATE)) == 0 {
                compile_expr(co, t.a);
                ch_op_u16(ch, OP_DELPROP, name_const(co, t.name));
            } else if t.kind == N_INDEX && (t.flags & NF_OPT_CHAIN) == 0 {
                compile_expr(co, t.a);
                compile_expr(co, t.b);
                ch_op(ch, OP_DELINDEX);
            } else {
                compile_expr(co, t);
                ch_op(ch, OP_POP);
                ch_op(ch, OP_FALSE);
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
        if n.op == TOK_PLUS { ch_op(ch, OP_TONUM); return; }
        if n.op == TOK_BANG { ch_op(ch, OP_NOT); return; }
        if n.op == TOK_TILDE { ch_op(ch, OP_BITNOT); return; }
        cerror(co, n, "unsupported unary operator");
        return;
    }
    if k == N_UPDATE { compile_update(co, n); return; }
    if k == N_MEMBER {
        if n.a.kind == N_SUPER {
            if !super_available(co) {
                cerror(co, n, "super outside a class method");
                ch_op(ch, OP_UNDEF);
                return;
            }
            emit_load_name(co, "%super", n);
            ch_op_u16(ch, OP_GETPROP, name_const(co, "prototype"));
            ch_op_u16(ch, OP_GETPROP, name_const(co, n.name));
            return;
        }
        if (n.flags & NF_PRIVATE) != 0 {
            compile_expr(co, n.a);
            ch_op_u16(ch, OP_GETPROP, private_key_const(co, n.name));
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
            emit_load_name(co, "%super", n);
            ch_op_u16(ch, OP_GETPROP, name_const(co, "prototype"));
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
        if !co.cur.is_gen {
            cerror(co, n, "yield outside a generator");
            ch_op(ch, OP_UNDEF);
            return;
        }
        if (n.flags & NF_DELEGATE) != 0 {
            // yield*: iterate the operand, yielding each value; the
            // expression result is the inner iterator's return value
            compile_expr(co, n.a);
            ch_op(ch, OP_GET_ITER);
            i32 t_it = alloc_slot(co.cur);
            ch_op_u16(ch, OP_SETLOCAL, t_it);
            ch_op(ch, OP_POP);
            i32 lstart = ch_pos(ch);
            ch_op_u16(ch, OP_GETLOCAL, t_it);
            ch_op(ch, OP_ITER_NEXT);       // [value, done]
            i32 jdone = ch_jump(ch, OP_JUMPT);
            ch_op(ch, OP_YIELD);           // yield value; discard resume input
            ch_op(ch, OP_POP);
            ch_op_u16(ch, OP_JUMP, lstart);
            ch_patch(ch, jdone);           // [value] — the final iterator value
            co.cur.cur_slots--;
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
        if !co.cur.is_async {
            cerror(co, n, "await outside an async function");
            ch_op(ch, OP_UNDEF);
            return;
        }
        compile_expr(co, n.a);
        ch_op(ch, OP_YIELD);
        return;
    }
    cerror(co, n, "expression not supported yet");
    ch_op(ch, OP_UNDEF);
}

// --- functions ---------------------------------------------------------------------

// Compiles f into a template. `fields` (class members) inject
// this-assignments into the body after a leading super() call.
private FnTemplate* compile_function_tmpl(Compiler* co, Node* f, Node** fields, i32 n_fields, bool self_name) {
    FScope fs;
    fscope_init(&fs, co.cur, (f.flags & NF_ARROW) != 0);
    fs.is_gen = (f.flags & NF_GENERATOR) != 0;
    fs.is_async = (f.flags & NF_ASYNC) != 0;
    co.cur = &fs;
    scan_inner(&fs.inner, f, true);
    for i32 i = 0; i < n_fields; i++ {
        scan_inner(&fs.inner, *(fields + i), true);
    }

    // params
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
            ignore declare(co, prm.a.name, false, false);
        } else {
            ignore declare(co, hidden_name(co, "%p", i), false, false);
        }
        n_params++;
    }
    // defaults
    for i32 i = 0; i < f.kids.len; i++ {
        Node* prm = *(f.kids.items + i);
        if prm.b == null { continue; }
        ch_op_u16(&fs.ch, OP_GETLOCAL, i);
        ch_op(&fs.ch, OP_UNDEF);
        ch_op(&fs.ch, OP_SEQ);
        i32 j = ch_jump(&fs.ch, OP_JUMPF);
        // named evaluation: an anonymous default takes the parameter's name
        if prm.a != null && prm.a.kind == N_IDENT { infer_name(prm.b, prm.a.name); }
        compile_expr(co, prm.b);
        ch_op_u16(&fs.ch, OP_SETLOCAL, i);
        ch_op(&fs.ch, OP_POP);
        ch_patch(&fs.ch, j);
    }
    // boxing of captured params
    for i32 i = 0; i < n_params; i++ {
        CBind b = vec_get(&fs.binds, i);
        if b.is_cell {
            ch_op_u16(&fs.ch, OP_CELLIFY, b.slot);
        }
    }
    // pattern params destructure into their names
    for i32 i = 0; i < f.kids.len; i++ {
        Node* prm = *(f.kids.items + i);
        if prm.a.kind == N_IDENT { continue; }
        declare_pattern(co, prm.a, 2);
        CBind pb = vec_get(&fs.binds, i);
        ch_op_u16(&fs.ch, pb.is_cell ? OP_GETCELL : OP_GETLOCAL, pb.slot);
        compile_destructure(co, prm.a, true);
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
    t.src_name = co.src_name;
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
    co.cur = fs.parent;
    fscope_free(&fs);
    return t;
}

private void compile_function(Compiler* co, Node* f, bool self_name) {
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

private bool member_is_field(Node* m) {
    if m.kind != N_CLASS_MEMBER { return false; }
    if (m.flags & NF_STATIC) != 0 { return false; }
    if m.b != null && m.b.kind == N_FUNCTION { return false; }
    return true;
}

// Leaves the class constructor function on the stack.
private void compile_class_expr(Compiler* co, Node* c) {
    FScope* fs = co.cur;
    Chunk* ch = &fs.ch;
    bool derived = c.a != null;

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

    // Inner class-name binding: inside the class body the class name refers to
    // the class itself, initialized before static blocks and static field
    // initializers run — unlike the outer binding a class *statement* adds,
    // which is still in TDZ during class creation. `declare` cellifies it
    // automatically when a method or field initializer closes over it.
    i32 name_bind = 0 - 1;
    if c.name.len > 0 {
        name_bind = declare(co, c.name, true, false);
        CBind* nb = fs.binds.data + name_bind;
        if nb.is_cell { ch_op_u16(ch, OP_NEWCELL_UNDEF, nb.slot); }
    }

    // partition members
    Vec<NodePtr> fields = vec_new<NodePtr>(4);
    Node* ctor_member = null;
    bool has_static = false;
    for i32 i = 0; i < c.kids.len; i++ {
        Node* m = *(c.kids.items + i);
        if m.kind == N_STATIC_BLOCK { has_static = true; continue; }
        if m.kind != N_CLASS_MEMBER { continue; }
        if (m.flags & NF_STATIC) == 0 && m.b != null && m.b.kind == N_FUNCTION
            && (m.flags & (NF_GETTER | NF_SETTER)) == 0
            && m.a != null && m.a.kind == N_IDENT && str_equal(m.a.name, "constructor") {
            ctor_member = m;
            continue;
        }
        if member_is_field(m) {
            vec_push(&fields, m);
            continue;
        }
        // a static data member (static field) also runs with `this` = the class
        if (m.flags & NF_STATIC) != 0 && (m.b == null || m.b.kind != N_FUNCTION)
            && (m.flags & (NF_GETTER | NF_SETTER)) == 0 {
            has_static = true;
        }
    }

    // constructor template
    Node* ctor_fn = null;
    if ctor_member != null {
        ctor_fn = ctor_member.b;
    } else {
        ctor_fn = build_default_ctor(co, derived);
    }
    FnTemplate* ct = compile_function_tmpl(co, ctor_fn, fields.data, fields.len, false);
    if c.name.len > 0 { tmpl_set_name(ct, c.name); }
    vec_push(&ch.subs, ct);
    ch_op_u16(ch, OP_CLOSURE, ch.subs.len - 1);

    i32 t_ctor = alloc_slot(fs);
    ch_op_u16(ch, OP_SETLOCAL, t_ctor);
    ch_op(ch, OP_POP);

    // Bind the inner class name to the freshly built constructor, so static
    // blocks / fields and any closure over it see the class value.
    if name_bind >= 0 {
        ch_op_u16(ch, OP_GETLOCAL, t_ctor);
        emit_init_binding(co, name_bind);
    }

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

    // members
    for i32 i = 0; i < c.kids.len; i++ {
        Node* m = *(c.kids.items + i);
        if m.kind == N_STATIC_BLOCK { continue; }
        if m.kind != N_CLASS_MEMBER || m == ctor_member { continue; }
        bool is_static = (m.flags & NF_STATIC) != 0;
        bool is_method = m.b != null && m.b.kind == N_FUNCTION;
        bool is_acc = (m.flags & (NF_GETTER | NF_SETTER)) != 0;
        if is_method {
            ch_op_u16(ch, OP_GETLOCAL, is_static ? t_ctor : t_proto);
            if (m.flags & NF_COMPUTED) != 0 {
                compile_expr(co, m.a);
                compile_function(co, m.b, false);
                if is_acc {
                    i32 aop = (m.flags & NF_GETTER) != 0 ? OP_DEFGETTER_DYN : OP_DEFSETTER_DYN;
                    ch_op_u16(ch, aop, 0);   // class accessors are non-enumerable
                } else {
                    ch_op(ch, OP_SETINDEX);
                }
                ch_op(ch, OP_POP);
            } else if is_acc {
                compile_function(co, m.b, false);
                i32 aop = (m.flags & NF_GETTER) != 0 ? OP_DEFGETTER : OP_DEFSETTER;
                ch_op_u16(ch, aop, prop_key_const(co, m.a));
                ch_u16(ch, 0);   // class accessors are non-enumerable
                ch_op(ch, OP_POP);
            } else {
                compile_function(co, m.b, false);
                ch_op_u16(ch, OP_DEFMETHOD, prop_key_const(co, m.a));
                ch_op(ch, OP_POP);
            }
            continue;
        }
        if is_static {
            ch_op_u16(ch, OP_GETLOCAL, t_ctor);
            bool saved_st = co.static_this;
            if (m.flags & NF_COMPUTED) != 0 {
                compile_expr(co, m.a);   // computed key keeps the outer `this`
                co.static_this = true;
                if m.b != null { compile_expr(co, m.b); } else { ch_op(ch, OP_UNDEF); }
                co.static_this = saved_st;
                ch_op(ch, OP_SETINDEX);
            } else {
                co.static_this = true;
                if m.b != null { compile_expr(co, m.b); } else { ch_op(ch, OP_UNDEF); }
                co.static_this = saved_st;
                ch_op_u16(ch, OP_SETPROP, prop_key_const(co, m.a));
            }
            ch_op(ch, OP_POP);
        }
        // instance fields run inside the constructor
    }
    // static blocks execute at class creation, in order
    for i32 i = 0; i < c.kids.len; i++ {
        Node* m = *(c.kids.items + i);
        if m.kind == N_STATIC_BLOCK {
            bool saved_st = co.static_this;
            co.static_this = true;
            compile_stmt(co, m.a);
            co.static_this = saved_st;
        }
    }

    ch_op_u16(ch, OP_GETLOCAL, t_ctor);
    vec_free(&fields);
    fs.binds.len = saved_binds;
    fs.cur_slots = saved_slots;
    fs.depth--;
}

// --- statements ------------------------------------------------------------------------

private void inline_finallys(Compiler* co, i32 down_to) {
    FScope* fs = co.cur;
    i32 saved = fs.finallys.len;
    for i32 i = fs.finallys.len - 1; i >= down_to; i-- {
        Node* fin = vec_get(&fs.finallys, i);
        fs.finallys.len = i;
        compile_stmt(co, fin);
    }
    fs.finallys.len = saved;
}

// Named evaluation: an anonymous function or class assigned to a name
// takes that name (const f = () => {} → f.name === "f").
private void infer_name(Node* init, str name) {
    if init == null || name.len == 0 { return; }
    if (init.kind == N_FUNCTION || init.kind == N_CLASS) && init.name.len == 0 {
        init.name = name;
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

// Block statement list with optional class-field injection after a
// leading super() call (constructors only).
private void compile_block_stmts_ex(Compiler* co, NodeList* list, Node** fields, i32 n_fields) {
    FScope* fs = co.cur;
    fs.depth++;
    i32 saved_binds = fs.binds.len;
    i32 saved_slots = fs.cur_slots;

    // lexical declarations hoist to block top as TDZ holes
    for i32 i = 0; i < list.len; i++ {
        Node* s = *(list.items + i);
        if s.kind == N_VAR && (s.flags & (NF_LET | NF_CONST)) != 0 {
            for i32 j = 0; j < s.kids.len; j++ {
                Node* d = *(s.kids.items + j);
                declare_pattern(co, d.a, (s.flags & NF_CONST) != 0 ? 1 : 0);
            }
        }
        if s.kind == N_CLASS && s.name.len > 0 {
            declare_lexical(co, s.name, false);
        }
    }
    // function declarations bind and initialize first
    for i32 i = 0; i < list.len; i++ {
        Node* s = *(list.items + i);
        if s.kind == N_FUNCTION && s.name.len > 0 {
            declare_plain(co, s.name);
        }
    }
    for i32 i = 0; i < list.len; i++ {
        Node* s = *(list.items + i);
        if s.kind == N_FUNCTION && s.name.len > 0 {
            i32 li = find_local(fs, s.name);
            compile_function(co, s, false);
            emit_init_binding(co, li);
        }
    }

    bool injected = n_fields == 0;
    for i32 i = 0; i < list.len; i++ {
        Node* s = *(list.items + i);
        if s.kind == N_FUNCTION && s.name.len > 0 { continue; }
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
        if (m.flags & NF_COMPUTED) != 0 {
            compile_expr(co, m.a);
            if m.b != null { compile_expr(co, m.b); } else { ch_op(ch, OP_UNDEF); }
            ch_op(ch, OP_SETINDEX);
        } else {
            if m.b != null { compile_expr(co, m.b); } else { ch_op(ch, OP_UNDEF); }
            ch_op_u16(ch, OP_SETPROP, prop_key_const(co, m.a));
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
        declare_pattern(co, pattern, 2);
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
    ch_op(ch, OP_GET_ITER);
    i32 t_iter = alloc_slot(fs);
    ch_op_u16(ch, OP_SETLOCAL, t_iter);
    ch_op(ch, OP_POP);

    i32 bind_start = fs.binds.len;
    Node* pattern = null;
    if n.a.kind == N_VAR {
        pattern = (*(n.a.kids.items)).a;
        declare_pattern(co, pattern, 2);
    }
    i32 bind_end = fs.binds.len;

    LoopCtx lc = make_loop_ctx(co, true);
    i32 lcond = ch_pos(ch);
    // result = await iter.next()
    ch_op_u16(ch, OP_GETLOCAL, t_iter);
    ch_op_u16(ch, OP_GETMETHOD, name_const(co, "next"));
    ch_op_u16(ch, OP_CALL, 0);
    ch_op(ch, OP_YIELD);
    // if result.done: break (leaving result on the stack for the pop)
    ch_op(ch, OP_DUP);
    ch_op_u16(ch, OP_GETPROP, name_const(co, "done"));
    i32 jend = ch_jump(ch, OP_JUMPT);
    // value = await result.value
    ch_op_u16(ch, OP_GETPROP, name_const(co, "value"));
    ch_op(ch, OP_YIELD);

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

    i32 bind_start = fs.binds.len;
    Node* pattern = null;
    if n.a.kind == N_VAR {
        pattern = (*(n.a.kids.items)).a;
        declare_pattern(co, pattern, 2);
    }
    i32 bind_end = fs.binds.len;

    LoopCtx lc = make_loop_ctx(co, true);
    i32 lcond = ch_pos(ch);
    ch_op_u16(ch, OP_GETLOCAL, t_iter);
    ch_op(ch, OP_ITER_NEXT);       // [value, done]
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
            for i32 i = fs.loops.len - 1; i >= 0; i-- {
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
            if fs.loops.len == 0 {
                cerror(co, n, "break/continue outside a loop");
                return;
            }
            li = fs.loops.len - 1;
            if k == N_CONTINUE {
                while li >= 0 {
                    LoopCtx c = vec_get(&fs.loops, li);
                    if c.is_loop { break; }
                    li--;
                }
                if li < 0 {
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
        if fs.parent == null {
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
        if fin != null { vec_push(&fs.finallys, fin); }
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
                vec_push(&fs.finallys, fin);
            }
            fs.depth++;
            i32 saved_binds = fs.binds.len;
            i32 saved_slots = fs.cur_slots;
            if cat.a != null {
                declare_pattern(co, cat.a, 2);
                compile_destructure(co, cat.a, true);
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
                ch_op(ch, OP_THROW);
                ch_patch(ch, jend2);
            }
        } else {
            compile_stmt(co, fin);
            ch_op(ch, OP_THROW);
        }
        ch_patch(ch, jend);
        return;
    }
    if k == N_SWITCH {
        compile_expr(co, n.a);
        i32 tmp = alloc_slot(fs);
        ch_op_u16(ch, OP_SETLOCAL, tmp);
        ch_op(ch, OP_POP);
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
        fs.depth++;
        i32 saved_binds = fs.binds.len;
        i32 saved_slots = fs.cur_slots;
        for i32 i = 0; i < n.kids.len; i++ {
            Node* c = *(n.kids.items + i);
            i32 j = vec_get(&case_jumps, i);
            if j >= 0 {
                ch_patch(ch, j);
            } else {
                ch_patch(ch, jdefault);
            }
            for i32 s = 0; s < c.kids.len; s++ {
                compile_stmt(co, *(c.kids.items + s));
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

FnTemplate* compile_program(Compiler* co, Node* prog) {
    FScope fs;
    fscope_init(&fs, null, false);
    co.cur = &fs;
    scan_inner(&fs.inner, prog, true);
    hoist_vars(co, prog);
    compile_block_stmts(co, &prog.kids);
    ch_op(&fs.ch, OP_UNDEF);
    ch_op(&fs.ch, OP_RETURN);
    str empty;
    empty.data = null;
    empty.len = 0;
    FnTemplate* t = chunk_finish(&fs.ch, empty, 0, fs.n_slots, false, false, false);
    t.src_name = co.src_name;
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
    hoist_vars(co, prog);
    compile_block_stmts(co, &prog.kids);
    ch_op(&fs.ch, OP_UNDEF);
    ch_op(&fs.ch, OP_RETURN);
    str empty;
    empty.data = null;
    empty.len = 0;
    FnTemplate* t = chunk_finish(&fs.ch, empty, 5, fs.n_slots, false, false, false);
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
private void register_import(Compiler* co, str slot_name, str prop, str local) {
    ModImport mi;
    mi.slot_name = slot_name;
    mi.prop = prop;
    strmap_set<ModImport>(&co.mod_imports, local, mi);
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
FnTemplate* compile_module(Compiler* co, Node* prog, Vec<str>* out_specs) {
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

    co.in_module = true;
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
            register_import(co, slot_name, "default", s.a.name);
        }
        if s.b != null {
            i32 bi = declare(co, s.b.name, true, false);
            CBind b = vec_get(&fs.binds, bi);
            emit_load_name(co, slot_name, null);
            if b.is_cell {
                ch_op_u16(&fs.ch, OP_NEWCELL_UNDEF, b.slot);
                ch_op_u16(&fs.ch, OP_SETCELL, b.slot);
            } else {
                ch_op_u16(&fs.ch, OP_SETLOCAL, b.slot);
            }
            ch_op(&fs.ch, OP_POP);
        }
        for i32 j = 0; j < s.kids.len; j++ {
            Node* sp = *(s.kids.items + j);
            register_import(co, slot_name, sp.name, sp.a.name);
        }
    }

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
            declare_lexical(co, d.name, false);
        }
    }

    // 6. top-level function declarations (hoisted), mirrored if exported
    for i32 i = 0; i < prog.kids.len; i++ {
        Node* s = *(prog.kids.items + i);
        bool exported = s.kind == N_EXPORT;
        Node* d = exported && s.a != null ? s.a : s;
        if d != null && d.kind == N_FUNCTION && d.name.len > 0 {
            declare_plain(co, d.name);
        }
    }
    for i32 i = 0; i < prog.kids.len; i++ {
        Node* s = *(prog.kids.items + i);
        bool exported = s.kind == N_EXPORT;
        bool is_default = exported && (s.flags & NF_DEFAULT) != 0;
        Node* d = exported && s.a != null ? s.a : s;
        if d != null && d.kind == N_FUNCTION && d.name.len > 0 {
            i32 li = find_local(&fs, d.name);
            compile_function(co, d, false);
            emit_init_binding(co, li);
            if exported && !is_default {
                mirror_export(co, ns_name, d.name, d.name);
            }
            if is_default {
                mirror_export(co, ns_name, d.name, "default");
            }
        }
    }

    // 7. body
    for i32 i = 0; i < prog.kids.len; i++ {
        Node* s = *(prog.kids.items + i);
        if s.kind == N_IMPORT { continue; }
        if s.kind == N_FUNCTION && s.name.len > 0 { continue; }
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
            ch_op(ch, OP_OBJ_SPREAD);
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

    // export { a, b as c }
    if s.a == null {
        for i32 i = 0; i < s.kids.len; i++ {
            Node* sp = *(s.kids.items + i);
            str exported = sp.a != null ? sp.a.name : sp.name;
            mirror_export(co, ns_name, sp.name, exported);
        }
        return;
    }

    Node* d = s.a;
    if is_default {
        // export default <expr | class-expr | function-expr>
        emit_load_name(co, ns_name, null);
        compile_expr(co, d);
        ch_op_u16(ch, OP_SETPROP, name_const(co, "default"));
        ch_op(ch, OP_POP);
        return;
    }

    if d.kind == N_VAR {
        compile_var_stmt(co, d);
        Vec<str> names = vec_new<str>(4);
        for i32 i = 0; i < d.kids.len; i++ {
            collect_pattern_names((*(d.kids.items + i)).a, &names);
        }
        for i32 i = 0; i < names.len; i++ {
            str nm = vec_get(&names, i);
            mirror_export(co, ns_name, nm, nm);
        }
        vec_free(&names);
        return;
    }
    if d.kind == N_CLASS && d.name.len > 0 {
        i32 li = find_local(co.cur, d.name);
        compile_class_expr(co, d);
        if li >= 0 { emit_init_binding(co, li); } else { ch_op(ch, OP_POP); }
        mirror_export(co, ns_name, d.name, d.name);
        return;
    }
    // interface/type-alias already stripped; anything else: compile as stmt
    compile_stmt(co, d);
}

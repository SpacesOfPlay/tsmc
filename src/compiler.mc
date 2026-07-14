// compiler.mc — lowered AST to bytecode.
//
// Scope analysis is fused with emission: an inner-name scan decides
// which bindings become heap boxes, var hoisting runs per function,
// let/const get TDZ holes at block entry. Unsupported constructs get
// "not supported yet" diagnostics. See doc/DESIGN_bytecode.md.

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

struct LoopCtx {
    bool is_loop;      // false for switch (break only)
    i32 break_mark;
    i32 cont_mark;
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
    Vec<i32> break_jumps;
    Vec<i32> cont_jumps;
    Vec<LoopCtx> loops;
    Vec<NodePtr> finallys;
}

struct Compiler {
    DiagList* diags;
    GcHeap* heap;
    AtomTable* atoms;
    FScope* cur;
}

void compiler_init(Compiler* co, DiagList* diags, GcHeap* heap, AtomTable* atoms) {
    co.diags = diags;
    co.heap = heap;
    co.atoms = atoms;
    co.cur = null;
}

private void cerror(Compiler* co, Node* n, str msg) {
    diag_add(co.diags, DIAG_ERROR, n.span, msg);
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
    vec_init<i32>(&fs.break_jumps, 8);
    vec_init<i32>(&fs.cont_jumps, 8);
    vec_init<LoopCtx>(&fs.loops, 4);
    vec_init<NodePtr>(&fs.finallys, 4);
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
        if v == 0.0 && 1.0 / v < 0.0 { return value_number(v); }   // -0
        return value_int(i);
    }
    return value_number(v);
}

// Compile-time GC strings stay rooted until the VM owns the templates.
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

// --- inner-name scan ---------------------------------------------------------

private void scan_all_names(StrMap<i32>* set, Node* n) {
    if n == null { return; }
    if n.kind == N_IDENT && n.name.len > 0 {
        strmap_set<i32>(set, n.name, 1);
    }
    if n.kind == N_THIS {
        strmap_set<i32>(set, "this", 1);
    }
    scan_all_names(set, n.a);
    scan_all_names(set, n.b);
    scan_all_names(set, n.c);
    scan_all_names(set, n.d);
    for i32 i = 0; i < n.kids.len; i++ {
        scan_all_names(set, *(n.kids.items + i));
    }
}

// Collects names used by nested functions of fn (not fn itself).
private void scan_inner(StrMap<i32>* set, Node* n, bool root) {
    if n == null { return; }
    if n.kind == N_FUNCTION && !root {
        scan_all_names(set, n);
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

// --- var hoisting ----------------------------------------------------------

private void hoist_declare_var(Compiler* co, Node* id) {
    if id.kind != N_IDENT {
        cerror(co, id, "destructuring is not supported yet");
        return;
    }
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
            hoist_declare_var(co, d.a);
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
    ch_op_u16(&fs.ch, OP_GETGLOBAL, name_const(co, n.name));
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
    ch_op_u16(&fs.ch, OP_SETGLOBAL, name_const(co, n.name));
}

// Direct store for initialization; bypasses the const check.
private void emit_init_binding(Compiler* co, i32 bind_idx) {
    FScope* fs = co.cur;
    CBind b = vec_get(&fs.binds, bind_idx);
    ch_op_u16(&fs.ch, b.is_cell ? OP_SETCELL : OP_SETLOCAL, b.slot);
    ch_op(&fs.ch, OP_POP);
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

// Compound-assign operator token → underlying binary opcode.
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

private void compile_assign(Compiler* co, Node* n) {
    Chunk* ch = &co.cur.ch;
    Node* t = n.a;
    if n.op == TOK_EQ {
        if t.kind == N_IDENT {
            compile_expr(co, n.b);
            emit_store_ident(co, t);
            return;
        }
        if t.kind == N_MEMBER {
            if (t.flags & (NF_OPT_CHAIN | NF_PRIVATE)) != 0 {
                cerror(co, t, "not supported yet");
                return;
            }
            compile_expr(co, t.a);
            compile_expr(co, n.b);
            ch_op_u16(ch, OP_SETPROP, name_const(co, t.name));
            return;
        }
        if t.kind == N_INDEX {
            compile_expr(co, t.a);
            compile_expr(co, t.b);
            compile_expr(co, n.b);
            ch_op(ch, OP_SETINDEX);
            return;
        }
        cerror(co, t, "destructuring assignment is not supported yet");
        return;
    }
    if n.op == TOK_AMPAMP_EQ || n.op == TOK_PIPEPIPE_EQ || n.op == TOK_QUESTION_QUESTION_EQ {
        if t.kind != N_IDENT {
            cerror(co, t, "logical assignment to members is not supported yet");
            return;
        }
        i32 jop = OP_JF_KEEP;
        if n.op == TOK_PIPEPIPE_EQ { jop = OP_JT_KEEP; }
        if n.op == TOK_QUESTION_QUESTION_EQ { jop = OP_JNN_KEEP; }
        emit_load_ident(co, t);
        i32 j = ch_jump(ch, jop);
        compile_expr(co, n.b);
        emit_store_ident(co, t);
        ch_patch(ch, j);
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
        compile_expr(co, t.a);
        ch_op(ch, OP_DUP);
        ch_op_u16(ch, OP_GETPROP, name_const(co, t.name));
        compile_expr(co, n.b);
        ch_op(ch, op);
        ch_op_u16(ch, OP_SETPROP, name_const(co, t.name));
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
    i32 op = n.op == TOK_PLUSPLUS ? OP_ADD : OP_SUB;
    bool prefix = (n.flags & NF_PREFIX) != 0;
    i32 one = ch_add_const(ch, value_int(1));
    if t.kind == N_IDENT {
        emit_load_ident(co, t);
        ch_op(ch, OP_TONUM);
        if !prefix { ch_op(ch, OP_DUP); }
        ch_op_u16(ch, OP_CONST, one);
        ch_op(ch, op);
        emit_store_ident(co, t);
        if !prefix { ch_op(ch, OP_POP); }
        return;
    }
    if t.kind == N_MEMBER || t.kind == N_INDEX {
        i32 tmp = alloc_slot(co.cur);
        if t.kind == N_MEMBER {
            compile_expr(co, t.a);
            ch_op(ch, OP_DUP);
            ch_op_u16(ch, OP_GETPROP, name_const(co, t.name));
        } else {
            compile_expr(co, t.a);
            compile_expr(co, t.b);
            ch_op(ch, OP_DUP2);
            ch_op(ch, OP_GETINDEX);
        }
        ch_op(ch, OP_TONUM);
        ch_op_u16(ch, OP_SETLOCAL, tmp);        // old numeric value
        ch_op_u16(ch, OP_CONST, one);
        ch_op(ch, op);
        if t.kind == N_MEMBER {
            ch_op_u16(ch, OP_SETPROP, name_const(co, t.name));
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

private void compile_call(Compiler* co, Node* n) {
    Chunk* ch = &co.cur.ch;
    if (n.flags & NF_OPT_CHAIN) != 0 {
        cerror(co, n, "optional chaining is not supported yet");
        return;
    }
    Node* callee = n.a;
    if callee.kind == N_MEMBER && (callee.flags & (NF_OPT_CHAIN | NF_PRIVATE)) == 0 {
        compile_expr(co, callee.a);
        ch_op_u16(ch, OP_GETMETHOD, name_const(co, callee.name));
    } else if callee.kind == N_INDEX && (callee.flags & NF_OPT_CHAIN) == 0 {
        compile_expr(co, callee.a);
        compile_expr(co, callee.b);
        ch_op(ch, OP_GETMETHOD_DYN);
    } else {
        compile_expr(co, callee);
        ch_op(ch, OP_UNDEF);
    }
    for i32 i = 0; i < n.kids.len; i++ {
        Node* arg = *(n.kids.items + i);
        if arg.kind == N_SPREAD {
            cerror(co, arg, "spread arguments are not supported yet");
            ch_op(ch, OP_UNDEF);
        } else {
            compile_expr(co, arg);
        }
    }
    ch_op_u16(ch, OP_CALL, n.kids.len);
}

private void compile_expr(Compiler* co, Node* n) {
    Chunk* ch = &co.cur.ch;
    i32 k = n.kind;
    if k == N_NUMBER {
        ch_op_u16(ch, OP_CONST, ch_add_const(ch, num_value(n.num)));
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
    if k == N_IDENT { emit_load_ident(co, n); return; }
    if k == N_THIS {
        if co.cur.is_arrow {
            Node tmp;
            tmp.kind = N_IDENT;
            tmp.name = "this";
            tmp.span = n.span;
            FScope* fs = co.cur;
            if find_local(fs, tmp.name) >= 0 || resolve_upval(fs, tmp.name) >= 0 {
                emit_load_ident(co, &tmp);
                return;
            }
        }
        ch_op(ch, OP_THIS);
        return;
    }
    if k == N_ARRAY {
        for i32 i = 0; i < n.kids.len; i++ {
            Node* e = *(n.kids.items + i);
            if e.kind == N_HOLE {
                ch_op(ch, OP_UNDEF);
            } else if e.kind == N_SPREAD {
                cerror(co, e, "spread is not supported yet");
                ch_op(ch, OP_UNDEF);
            } else {
                compile_expr(co, e);
            }
        }
        ch_op_u16(ch, OP_NEWARR, n.kids.len);
        return;
    }
    if k == N_OBJECT {
        ch_op(ch, OP_NEWOBJ);
        for i32 i = 0; i < n.kids.len; i++ {
            Node* p = *(n.kids.items + i);
            if p.kind == N_SPREAD {
                cerror(co, p, "object spread is not supported yet");
                continue;
            }
            if (p.flags & (NF_GETTER | NF_SETTER)) != 0 {
                cerror(co, p, "getters and setters are not supported yet");
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
            ch_op(ch, OP_DUP);
            if p.b != null {
                compile_expr(co, p.b);
            } else {
                // shorthand { x }
                Node tmp;
                tmp.kind = N_IDENT;
                tmp.name = p.a.name;
                tmp.span = p.span;
                emit_load_ident(co, &tmp);
            }
            if p.a.kind == N_NUMBER {
                // numeric keys stringify the JS way: 1, not 1.0
                i64 iv = cast(i64, p.a.num);
                string s;
                if cast(f64, iv) == p.a.num {
                    s = format("{}", iv);
                } else {
                    s = format("{}", p.a.num);
                }
                ch_op_u16(ch, OP_SETPROP, name_const(co, s));
                free(s);
            } else {
                ch_op_u16(ch, OP_SETPROP, name_const(co, p.a.name));
            }
            ch_op(ch, OP_POP);
        }
        return;
    }
    if k == N_TEMPLATE {
        // fold to string concatenation; first quasi anchors stringness
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
                ch_op(ch, OP_ADD);
            }
        }
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
            if t.kind == N_MEMBER && (t.flags & (NF_OPT_CHAIN | NF_PRIVATE)) == 0 {
                compile_expr(co, t.a);
                ch_op_u16(ch, OP_DELPROP, name_const(co, t.name));
            } else if t.kind == N_INDEX {
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
                if find_local(fs, n.a.name) < 0 && resolve_upval(fs, n.a.name) < 0 {
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
        if (n.flags & (NF_OPT_CHAIN | NF_PRIVATE)) != 0 {
            cerror(co, n, "not supported yet");
            return;
        }
        compile_expr(co, n.a);
        ch_op_u16(ch, OP_GETPROP, name_const(co, n.name));
        return;
    }
    if k == N_INDEX {
        if (n.flags & NF_OPT_CHAIN) != 0 {
            cerror(co, n, "optional chaining is not supported yet");
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
        for i32 i = 0; i < n.kids.len; i++ {
            Node* arg = *(n.kids.items + i);
            if arg.kind == N_SPREAD {
                cerror(co, arg, "spread arguments are not supported yet");
                ch_op(ch, OP_UNDEF);
            } else {
                compile_expr(co, arg);
            }
        }
        ch_op_u16(ch, OP_NEW, n.kids.len);
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
        compile_function(co, n);
        return;
    }
    cerror(co, n, "expression not supported yet");
    ch_op(ch, OP_UNDEF);
}

// --- functions ---------------------------------------------------------------------

private void compile_function(Compiler* co, Node* f) {
    FScope fs;
    fscope_init(&fs, co.cur, (f.flags & NF_ARROW) != 0);
    if (f.flags & (NF_ASYNC | NF_GENERATOR)) != 0 {
        cerror(co, f, "async and generator functions are not supported yet");
    }
    co.cur = &fs;
    scan_inner(&fs.inner, f, true);

    // params
    i32 n_params = 0;
    for i32 i = 0; i < f.kids.len; i++ {
        Node* prm = *(f.kids.items + i);
        if (prm.flags & NF_REST) != 0 {
            cerror(co, prm, "rest parameters are not supported yet");
        }
        if prm.a.kind != N_IDENT {
            cerror(co, prm, "destructured parameters are not supported yet");
            declare(co, "", false, false);
            n_params++;
            continue;
        }
        declare(co, prm.a.name, false, false);
        n_params++;
    }
    // defaults, then boxing of captured params
    for i32 i = 0; i < f.kids.len; i++ {
        Node* prm = *(f.kids.items + i);
        if prm.b == null { continue; }
        ch_op_u16(&fs.ch, OP_GETLOCAL, i);
        ch_op(&fs.ch, OP_UNDEF);
        ch_op(&fs.ch, OP_SEQ);
        i32 j = ch_jump(&fs.ch, OP_JUMPF);
        compile_expr(co, prm.b);
        ch_op_u16(&fs.ch, OP_SETLOCAL, i);
        ch_op(&fs.ch, OP_POP);
        ch_patch(&fs.ch, j);
    }
    for i32 i = 0; i < n_params; i++ {
        CBind b = vec_get(&fs.binds, i);
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

    if f.a != null && f.a.kind == N_BLOCK {
        hoist_vars(co, f.a);
        compile_block_stmts(co, &f.a.kids);
        ch_op(&fs.ch, OP_UNDEF);
        ch_op(&fs.ch, OP_RETURN);
    } else if f.a != null {
        compile_expr(co, f.a);
        ch_op(&fs.ch, OP_RETURN);
    } else {
        ch_op(&fs.ch, OP_UNDEF);
        ch_op(&fs.ch, OP_RETURN);
    }

    FnTemplate* t = chunk_finish(&fs.ch, f.name, n_params, fs.n_slots);
    co.cur = fs.parent;
    fscope_free(&fs);
    vec_push(&co.cur.ch.subs, t);
    ch_op_u16(&co.cur.ch, OP_CLOSURE, co.cur.ch.subs.len - 1);
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

private void compile_var_stmt(Compiler* co, Node* n) {
    bool lexical = (n.flags & (NF_LET | NF_CONST)) != 0;
    for i32 i = 0; i < n.kids.len; i++ {
        Node* d = *(n.kids.items + i);
        if d.a.kind != N_IDENT {
            cerror(co, d, "destructuring is not supported yet");
            continue;
        }
        i32 li = find_local(co.cur, d.a.name);
        if li < 0 {
            cerror(co, d, "unresolved declaration");
            continue;
        }
        if d.b != null {
            compile_expr(co, d.b);
            emit_init_binding(co, li);
        } else if lexical {
            if (n.flags & NF_CONST) != 0 {
                cerror(co, d, "const declaration needs an initializer");
            }
            ch_op(&co.cur.ch, OP_UNDEF);
            emit_init_binding(co, li);
        }
    }
}

private void compile_block_stmts(Compiler* co, NodeList* list) {
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
                if d.a.kind != N_IDENT { continue; }
                i32 bi = declare(co, d.a.name, (s.flags & NF_CONST) != 0, true);
                CBind b = vec_get(&fs.binds, bi);
                if b.is_cell {
                    ch_op_u16(&fs.ch, OP_NEWCELL_HOLE, b.slot);
                } else {
                    ch_op_u16(&fs.ch, OP_SETHOLE, b.slot);
                }
            }
        }
    }
    // function declarations bind and initialize first
    for i32 i = 0; i < list.len; i++ {
        Node* s = *(list.items + i);
        if s.kind == N_FUNCTION && s.name.len > 0 {
            i32 bi = declare(co, s.name, false, false);
            CBind b = vec_get(&fs.binds, bi);
            if b.is_cell {
                ch_op_u16(&fs.ch, OP_NEWCELL_UNDEF, b.slot);
            }
        }
    }
    for i32 i = 0; i < list.len; i++ {
        Node* s = *(list.items + i);
        if s.kind == N_FUNCTION && s.name.len > 0 {
            i32 li = find_local(fs, s.name);
            compile_function(co, s);
            emit_init_binding(co, li);
        }
    }
    for i32 i = 0; i < list.len; i++ {
        Node* s = *(list.items + i);
        if s.kind == N_FUNCTION && s.name.len > 0 { continue; }
        compile_stmt(co, s);
    }

    fs.binds.len = saved_binds;
    fs.cur_slots = saved_slots;
    fs.depth--;
}

private void patch_jumps(Compiler* co, Vec<i32>* jumps, i32 mark, i32 target) {
    Chunk* ch = &co.cur.ch;
    while jumps.len > mark {
        i32 at = vec_pop(jumps);
        ch_patch_to(ch, at, target);
    }
}

private void compile_stmt(Compiler* co, Node* n) {
    if n == null { return; }
    Chunk* ch = &co.cur.ch;
    FScope* fs = co.cur;
    i32 k = n.kind;

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
        i32 lcond = ch_pos(ch);
        compile_expr(co, n.a);
        i32 jend = ch_jump(ch, OP_JUMPF);
        LoopCtx lc;
        lc.is_loop = true;
        lc.break_mark = fs.break_jumps.len;
        lc.cont_mark = fs.cont_jumps.len;
        lc.fin_depth = fs.finallys.len;
        vec_push(&fs.loops, lc);
        compile_stmt(co, n.b);
        vec_pop(&fs.loops);
        patch_jumps(co, &fs.cont_jumps, lc.cont_mark, lcond);
        ch_op_u16(ch, OP_JUMP, lcond);
        ch_patch(ch, jend);
        patch_jumps(co, &fs.break_jumps, lc.break_mark, ch_pos(ch));
        return;
    }
    if k == N_DO_WHILE {
        i32 lstart = ch_pos(ch);
        LoopCtx lc;
        lc.is_loop = true;
        lc.break_mark = fs.break_jumps.len;
        lc.cont_mark = fs.cont_jumps.len;
        lc.fin_depth = fs.finallys.len;
        vec_push(&fs.loops, lc);
        compile_stmt(co, n.a);
        vec_pop(&fs.loops);
        i32 lcond = ch_pos(ch);
        patch_jumps(co, &fs.cont_jumps, lc.cont_mark, lcond);
        compile_expr(co, n.b);
        ch_op_u16(ch, OP_JUMPT, lstart);
        patch_jumps(co, &fs.break_jumps, lc.break_mark, ch_pos(ch));
        return;
    }
    if k == N_FOR {
        fs.depth++;
        i32 saved_binds = fs.binds.len;
        i32 saved_slots = fs.cur_slots;
        if n.a != null {
            if n.a.kind == N_VAR {
                if (n.a.flags & (NF_LET | NF_CONST)) != 0 {
                    for i32 j = 0; j < n.a.kids.len; j++ {
                        Node* d = *(n.a.kids.items + j);
                        if d.a.kind != N_IDENT { continue; }
                        i32 bi = declare(co, d.a.name, (n.a.flags & NF_CONST) != 0, true);
                        CBind b = vec_get(&fs.binds, bi);
                        if b.is_cell {
                            ch_op_u16(ch, OP_NEWCELL_HOLE, b.slot);
                        } else {
                            ch_op_u16(ch, OP_SETHOLE, b.slot);
                        }
                    }
                }
                compile_var_stmt(co, n.a);
            } else {
                compile_expr(co, n.a);
                ch_op(ch, OP_POP);
            }
        }
        i32 lcond = ch_pos(ch);
        i32 jend = -1;
        if n.b != null {
            compile_expr(co, n.b);
            jend = ch_jump(ch, OP_JUMPF);
        }
        LoopCtx lc;
        lc.is_loop = true;
        lc.break_mark = fs.break_jumps.len;
        lc.cont_mark = fs.cont_jumps.len;
        lc.fin_depth = fs.finallys.len;
        vec_push(&fs.loops, lc);
        compile_stmt(co, n.d);
        vec_pop(&fs.loops);
        i32 lcont = ch_pos(ch);
        patch_jumps(co, &fs.cont_jumps, lc.cont_mark, lcont);
        if n.c != null {
            compile_expr(co, n.c);
            ch_op(ch, OP_POP);
        }
        ch_op_u16(ch, OP_JUMP, lcond);
        if jend >= 0 { ch_patch(ch, jend); }
        patch_jumps(co, &fs.break_jumps, lc.break_mark, ch_pos(ch));
        fs.binds.len = saved_binds;
        fs.cur_slots = saved_slots;
        fs.depth--;
        return;
    }
    if k == N_BREAK || k == N_CONTINUE {
        if n.name.len > 0 {
            cerror(co, n, "labeled break/continue is not supported yet");
            return;
        }
        if fs.loops.len == 0 {
            cerror(co, n, "break/continue outside a loop");
            return;
        }
        i32 li = fs.loops.len - 1;
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
        LoopCtx lc = vec_get(&fs.loops, li);
        inline_finallys(co, lc.fin_depth);
        i32 j = ch_jump(ch, OP_JUMP);
        if k == N_BREAK {
            vec_push(&fs.break_jumps, j);
        } else {
            vec_push(&fs.cont_jumps, j);
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
            vec_pop(&fs.finallys);
            compile_stmt(co, fin);
        }
        i32 jend = ch_jump(ch, OP_JUMP);
        ch_patch(ch, jtry);
        // exception value is on the stack here
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
            if cat.a != null && cat.a.kind == N_IDENT {
                i32 bi = declare(co, cat.a.name, false, false);
                CBind b = vec_get(&fs.binds, bi);
                if b.is_cell {
                    ch_op_u16(ch, OP_NEWCELL_UNDEF, b.slot);
                    ch_op_u16(ch, OP_SETCELL, b.slot);
                } else {
                    ch_op_u16(ch, OP_SETLOCAL, b.slot);
                }
                ch_op(ch, OP_POP);
            } else {
                if cat.a != null {
                    cerror(co, cat.a, "destructured catch bindings are not supported yet");
                }
                ch_op(ch, OP_POP);
            }
            compile_stmt(co, cat.b);
            fs.binds.len = saved_binds;
            fs.cur_slots = saved_slots;
            fs.depth--;
            if fin != null {
                vec_pop(&fs.finallys);
                ch_op(ch, OP_TRY_POP);
                compile_stmt(co, fin);
                i32 jend2 = ch_jump(ch, OP_JUMP);
                ch_patch(ch, jfin);
                compile_stmt(co, fin);
                ch_op(ch, OP_THROW);
                ch_patch(ch, jend2);
            }
        } else {
            // try/finally: run finally, rethrow
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
        LoopCtx lc;
        lc.is_loop = false;
        lc.break_mark = fs.break_jumps.len;
        lc.cont_mark = fs.cont_jumps.len;
        lc.fin_depth = fs.finallys.len;
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
        vec_pop(&fs.loops);
        patch_jumps(co, &fs.break_jumps, lc.break_mark, ch_pos(ch));
        fs.cur_slots--;   // release tmp
        vec_free(&case_jumps);
        return;
    }
    if k == N_FUNCTION {
        // function expression statement (named ones bind at block entry)
        compile_function(co, n);
        ch_op(ch, OP_POP);
        return;
    }
    if k == N_DEBUGGER { return; }
    if k == N_CLASS {
        cerror(co, n, "classes are not supported yet");
        return;
    }
    if k == N_FOR_OF || k == N_FOR_IN {
        cerror(co, n, "for-of and for-in are not supported yet");
        return;
    }
    if k == N_LABELED {
        cerror(co, n, "labeled statements are not supported yet");
        return;
    }
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
    FnTemplate* t = chunk_finish(&fs.ch, empty, 0, fs.n_slots);
    co.cur = null;
    fscope_free(&fs);
    return t;
}

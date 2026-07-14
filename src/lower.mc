// lower.mc — TS-to-ES lowering over the AST.
//
// After lowering the tree is plain ES: type-only declarations are
// gone, as/non-null unwrap, enums and namespaces become var + IIFE,
// parameter properties become this-assignments. Nodes mutate in
// place; new nodes come from the same bump arena.
// See doc/PLAN_M4_lower.md.

import vec;
import str;
import diag;
import lexer;
import ast;
import bump;

struct Lower {
    Bump* arena;
    DiagList* diags;
    Vec<NodePtr> scratch;
}

void lower_init(Lower* lw, Bump* arena, DiagList* diags) {
    lw.arena = arena;
    lw.diags = diags;
    vec_init<NodePtr>(&lw.scratch, 32);
}

void lower_destroy(Lower* lw) {
    vec_free(&lw.scratch);
}

void lower_program(Lower* lw, Node* program) {
    lower_stmt_list(lw, &program.kids);
}

// --- node builders ----------------------------------------------------

private Node* mk(Lower* lw, i32 kind) {
    Node* n = cast(Node*, bump_alloc(lw.arena, cast(i32, sizeof(Node))));
    n.kind = kind;
    return n;
}

private NodeList list1(Lower* lw, Node* n0) {
    NodeList l;
    l.len = 1;
    l.items = cast(Node**, bump_alloc(lw.arena, 8));
    *(l.items) = n0;
    return l;
}

private NodeList kids_from_scratch(Lower* lw, i32 mark) {
    NodeList l;
    l.len = lw.scratch.len - mark;
    l.items = null;
    if l.len > 0 {
        l.items = cast(Node**, bump_alloc(lw.arena, l.len * 8));
        for i32 i = 0; i < l.len; i++ {
            *(l.items + i) = vec_get(&lw.scratch, mark + i);
        }
    }
    lw.scratch.len = mark;
    return l;
}

private Node* mk_ident(Lower* lw, str name) {
    Node* n = mk(lw, N_IDENT);
    n.name = name;
    return n;
}

private Node* mk_str(Lower* lw, str s) {
    Node* n = mk(lw, N_STRING);
    n.name = s;
    return n;
}

private Node* mk_num(Lower* lw, f64 v) {
    Node* n = mk(lw, N_NUMBER);
    n.num = v;
    return n;
}

private Node* mk_assign(Lower* lw, Node* a, Node* b) {
    Node* n = mk(lw, N_ASSIGN);
    n.op = TOK_EQ;
    n.a = a;
    n.b = b;
    return n;
}

private Node* mk_oror(Lower* lw, Node* a, Node* b) {
    Node* n = mk(lw, N_BIN);
    n.op = TOK_PIPEPIPE;
    n.a = a;
    n.b = b;
    return n;
}

private Node* mk_index(Lower* lw, Node* obj, Node* idx) {
    Node* n = mk(lw, N_INDEX);
    n.a = obj;
    n.b = idx;
    return n;
}

private Node* mk_member(Lower* lw, Node* obj, str name) {
    Node* n = mk(lw, N_MEMBER);
    n.a = obj;
    n.name = name;
    return n;
}

private Node* mk_exprstmt(Lower* lw, Node* e) {
    Node* n = mk(lw, N_EXPR_STMT);
    n.a = e;
    return n;
}

// var NAME; (plain var, no initializer)
private Node* mk_var(Lower* lw, str name) {
    Node* d = mk(lw, N_DECLARATOR);
    d.a = mk_ident(lw, name);
    Node* v = mk(lw, N_VAR);
    v.kids = list1(lw, d);
    return v;
}

// (function (PARAM) { BODY })(ARG);
private Node* mk_iife(Lower* lw, str param, Node* body_block, Node* arg) {
    Node* prm = mk(lw, N_PARAM);
    prm.a = mk_ident(lw, param);
    Node* fun = mk(lw, N_FUNCTION);
    fun.kids = list1(lw, prm);
    fun.a = body_block;
    Node* call = mk(lw, N_CALL);
    call.a = fun;
    call.kids = list1(lw, arg);
    return mk_exprstmt(lw, call);
}

// --- enum constant folding ----------------------------------------------

private i32 to_i32(f64 v) {
    return cast(i32, cast(i64, v));
}

private bool enum_fold(Lower* lw, Node* n, Vec<str>* names, Vec<f64>* vals, f64* out) {
    if n == null { return false; }
    if n.kind == N_NUMBER {
        *out = n.num;
        return true;
    }
    if n.kind == N_IDENT {
        for i32 i = 0; i < names.len; i++ {
            if str_equal(vec_get(names, i), n.name) {
                *out = vec_get(vals, i);
                return true;
            }
        }
        return false;
    }
    if n.kind == N_UNARY {
        f64 v;
        if !enum_fold(lw, n.a, names, vals, &v) { return false; }
        if n.op == TOK_MINUS { *out = -v; return true; }
        if n.op == TOK_PLUS { *out = v; return true; }
        if n.op == TOK_TILDE { *out = ~to_i32(v); return true; }
        return false;
    }
    if n.kind == N_BIN {
        f64 a;
        f64 b;
        if !enum_fold(lw, n.a, names, vals, &a) { return false; }
        if !enum_fold(lw, n.b, names, vals, &b) { return false; }
        i32 op = n.op;
        if op == TOK_PLUS { *out = a + b; return true; }
        if op == TOK_MINUS { *out = a - b; return true; }
        if op == TOK_STAR { *out = a * b; return true; }
        if op == TOK_SLASH { *out = a / b; return true; }
        if op == TOK_LSHIFT { *out = to_i32(a) << (to_i32(b) & 31); return true; }
        if op == TOK_RSHIFT { *out = to_i32(a) >> (to_i32(b) & 31); return true; }
        if op == TOK_URSHIFT {
            u32 ua = to_i32(a);
            *out = ua >> cast(u32, to_i32(b) & 31);
            return true;
        }
        if op == TOK_AMP { *out = to_i32(a) & to_i32(b); return true; }
        if op == TOK_PIPE { *out = to_i32(a) | to_i32(b); return true; }
        if op == TOK_CARET { *out = to_i32(a) ^ to_i32(b); return true; }
        return false;
    }
    return false;
}

// --- enum lowering --------------------------------------------------------

// Pushes: var E; (function (E) { members })(E || (E = {}));
private void lower_enum(Lower* lw, Node* e) {
    vec_push(&lw.scratch, mk_var(lw, e.name));

    Vec<str> names = vec_new<str>(8);
    Vec<f64> vals = vec_new<f64>(8);
    i32 bmark = lw.scratch.len;
    f64 next = 0.0;
    bool have_next = true;

    for i32 i = 0; i < e.kids.len; i++ {
        Node* m = *(e.kids.items + i);
        str key = m.a.name;
        Node* init = null;
        bool is_string = false;
        if m.b == null {
            if !have_next {
                diag_add(lw.diags, DIAG_ERROR, m.span,
                    "enum member needs an initializer after a non-constant member");
            }
            init = mk_num(lw, next);
            vec_push(&names, key);
            vec_push(&vals, next);
            next = next + 1.0;
        } else {
            lower_slot(lw, &m.b);
            if m.b.kind == N_STRING {
                is_string = true;
                init = m.b;
                have_next = false;
            } else {
                f64 v = 0.0;
                if enum_fold(lw, m.b, &names, &vals, &v) {
                    init = mk_num(lw, v);
                    vec_push(&names, key);
                    vec_push(&vals, v);
                    next = v + 1.0;
                    have_next = true;
                } else {
                    init = m.b;
                    have_next = false;
                }
            }
        }
        Node* target = mk_index(lw, mk_ident(lw, e.name), mk_str(lw, key));
        if is_string {
            vec_push(&lw.scratch, mk_exprstmt(lw, mk_assign(lw, target, init)));
        } else {
            Node* inner = mk_assign(lw, target, init);
            Node* outer = mk_assign(lw,
                mk_index(lw, mk_ident(lw, e.name), inner),
                mk_str(lw, key));
            vec_push(&lw.scratch, mk_exprstmt(lw, outer));
        }
    }
    vec_free(&names);
    vec_free(&vals);

    Node* body = mk(lw, N_BLOCK);
    body.kids = kids_from_scratch(lw, bmark);
    // E || (E = {})
    Node* arg = mk_oror(lw, mk_ident(lw, e.name),
        mk_assign(lw, mk_ident(lw, e.name), mk(lw, N_OBJECT)));
    vec_push(&lw.scratch, mk_iife(lw, e.name, body, arg));
}

// --- namespace lowering -----------------------------------------------------

// parent: enclosing namespace param name, empty at module/function level.
private void lower_namespace(Lower* lw, Node* ns, str parent) {
    vec_push(&lw.scratch, mk_var(lw, ns.name));
    i32 bmark = lw.scratch.len;

    for i32 i = 0; i < ns.kids.len; i++ {
        Node* s = *(ns.kids.items + i);
        if s.kind == N_NAMESPACE {
            if (s.flags & NF_EXPORTED) != 0 {
                lower_namespace(lw, s, ns.name);
            } else {
                lower_namespace(lw, s, "");
            }
            continue;
        }
        if s.kind == N_EXPORT && s.a != null {
            Node* d = s.a;
            i32 dk = d.kind;
            if dk == N_INTERFACE || dk == N_TYPE_ALIAS { continue; }
            if (d.flags & NF_DECLARE) != 0 { continue; }
            if dk == N_FUNCTION && (d.flags & NF_SIGNATURE) != 0 { continue; }
            if dk == N_ENUM {
                lower_enum(lw, d);
                vec_push(&lw.scratch, mk_exprstmt(lw, mk_assign(lw,
                    mk_member(lw, mk_ident(lw, ns.name), d.name),
                    mk_ident(lw, d.name))));
                continue;
            }
            if dk == N_NAMESPACE {
                lower_namespace(lw, d, ns.name);
                continue;
            }
            if dk == N_VAR {
                if (d.flags & NF_CONST) == 0 {
                    diag_add(lw.diags, DIAG_WARNING, d.span,
                        "reassignment of a mutable namespace export does not update the namespace object");
                }
                Node* tmp = d;
                lower_slot(lw, &tmp);
                vec_push(&lw.scratch, tmp);
                for i32 j = 0; j < d.kids.len; j++ {
                    Node* dec = *(d.kids.items + j);
                    if dec.a.kind == N_IDENT {
                        vec_push(&lw.scratch, mk_exprstmt(lw, mk_assign(lw,
                            mk_member(lw, mk_ident(lw, ns.name), dec.a.name),
                            mk_ident(lw, dec.a.name))));
                    } else {
                        diag_add(lw.diags, DIAG_WARNING, dec.span,
                            "destructured namespace exports are not supported");
                    }
                }
                continue;
            }
            if dk == N_FUNCTION || dk == N_CLASS {
                Node* tmp = d;
                lower_slot(lw, &tmp);
                vec_push(&lw.scratch, tmp);
                vec_push(&lw.scratch, mk_exprstmt(lw, mk_assign(lw,
                    mk_member(lw, mk_ident(lw, ns.name), d.name),
                    mk_ident(lw, d.name))));
                continue;
            }
            emit_stmt(lw, s);
            continue;
        }
        emit_stmt(lw, s);
    }

    Node* body = mk(lw, N_BLOCK);
    body.kids = kids_from_scratch(lw, bmark);
    Node* arg;
    if parent.len == 0 {
        // N || (N = {})
        arg = mk_oror(lw, mk_ident(lw, ns.name),
            mk_assign(lw, mk_ident(lw, ns.name), mk(lw, N_OBJECT)));
    } else {
        // N = P.N || (P.N = {})
        arg = mk_assign(lw, mk_ident(lw, ns.name),
            mk_oror(lw,
                mk_member(lw, mk_ident(lw, parent), ns.name),
                mk_assign(lw,
                    mk_member(lw, mk_ident(lw, parent), ns.name),
                    mk(lw, N_OBJECT))));
    }
    vec_push(&lw.scratch, mk_iife(lw, ns.name, body, arg));
}

// --- classes -----------------------------------------------------------------

private bool is_super_call_stmt(Node* s) {
    return s.kind == N_EXPR_STMT && s.a != null && s.a.kind == N_CALL
        && s.a.a != null && s.a.a.kind == N_SUPER;
}

private void lower_class(Lower* lw, Node* c) {
    lower_slot(lw, &c.a);
    i32 mark = lw.scratch.len;
    for i32 i = 0; i < c.kids.len; i++ {
        Node* m = *(c.kids.items + i);
        if m.kind == N_STATIC_BLOCK {
            lower_slot(lw, &m.a);
            vec_push(&lw.scratch, m);
            continue;
        }
        if (m.flags & NF_DECLARE) != 0 { continue; }
        if m.b != null && m.b.kind == N_FUNCTION && (m.b.flags & NF_SIGNATURE) != 0 {
            continue;
        }
        if m.b == null && (m.flags & NF_ABSTRACT) != 0 { continue; }
        lower_slot(lw, &m.a);
        lower_slot(lw, &m.b);
        vec_push(&lw.scratch, m);
    }
    c.kids = kids_from_scratch(lw, mark);

    // parameter properties → this-assignments in the constructor
    for i32 i = 0; i < c.kids.len; i++ {
        Node* m = *(c.kids.items + i);
        if m.kind != N_CLASS_MEMBER || m.b == null || m.b.kind != N_FUNCTION {
            continue;
        }
        if m.a == null || m.a.kind != N_IDENT || !str_equal(m.a.name, "constructor") {
            continue;
        }
        Node* fun = m.b;
        if fun.a == null || fun.a.kind != N_BLOCK { continue; }
        i32 amark = lw.scratch.len;
        for i32 j = 0; j < fun.kids.len; j++ {
            Node* prm = *(fun.kids.items + j);
            if (prm.flags & NF_PARAM_PROP) == 0 { continue; }
            if prm.a == null || prm.a.kind != N_IDENT {
                diag_add(lw.diags, DIAG_ERROR, prm.span,
                    "parameter properties require a plain identifier");
                continue;
            }
            Node* t = mk(lw, N_THIS);
            vec_push(&lw.scratch, mk_exprstmt(lw, mk_assign(lw,
                mk_member(lw, t, prm.a.name),
                mk_ident(lw, prm.a.name))));
        }
        i32 n_assign = lw.scratch.len - amark;
        if n_assign == 0 { continue; }

        Node* block = fun.a;
        i32 insert_at = 0;
        if c.a != null && block.kids.len > 0 && is_super_call_stmt(*(block.kids.items)) {
            insert_at = 1;
        }
        NodeList assigns = kids_from_scratch(lw, amark);
        i32 bmark = lw.scratch.len;
        for i32 j = 0; j < insert_at; j++ {
            vec_push(&lw.scratch, *(block.kids.items + j));
        }
        for i32 j = 0; j < assigns.len; j++ {
            vec_push(&lw.scratch, *(assigns.items + j));
        }
        for i32 j = insert_at; j < block.kids.len; j++ {
            vec_push(&lw.scratch, *(block.kids.items + j));
        }
        block.kids = kids_from_scratch(lw, bmark);
    }
}

// --- imports / exports ----------------------------------------------------

// Pushes the import unless every binding was type-only.
private void lower_import(Lower* lw, Node* n) {
    if (n.flags & NF_TYPE_ONLY) != 0 { return; }
    bool had = n.a != null || n.b != null || n.kids.len > 0;
    i32 mark = lw.scratch.len;
    for i32 i = 0; i < n.kids.len; i++ {
        Node* sp = *(n.kids.items + i);
        if (sp.flags & NF_TYPE_ONLY) == 0 { vec_push(&lw.scratch, sp); }
    }
    n.kids = kids_from_scratch(lw, mark);
    if had && n.a == null && n.b == null && n.kids.len == 0 { return; }
    vec_push(&lw.scratch, n);
}

private void lower_export(Lower* lw, Node* n) {
    if (n.flags & NF_TYPE_ONLY) != 0 { return; }
    if n.a != null {
        Node* d = n.a;
        i32 dk = d.kind;
        if dk == N_INTERFACE || dk == N_TYPE_ALIAS { return; }
        if (d.flags & NF_DECLARE) != 0 { return; }
        if dk == N_FUNCTION && (d.flags & NF_SIGNATURE) != 0 { return; }
        if dk == N_ENUM || dk == N_NAMESPACE {
            // lowered var picks up the export wrapper; IIFE follows
            i32 at = lw.scratch.len;
            if dk == N_ENUM {
                lower_enum(lw, d);
            } else {
                lower_namespace(lw, d, "");
            }
            n.a = vec_get(&lw.scratch, at);
            vec_set(&lw.scratch, at, n);
            return;
        }
        lower_slot(lw, &n.a);
        vec_push(&lw.scratch, n);
        return;
    }
    bool had_specs = n.kids.len > 0;
    i32 mark = lw.scratch.len;
    for i32 i = 0; i < n.kids.len; i++ {
        Node* sp = *(n.kids.items + i);
        if (sp.flags & NF_TYPE_ONLY) == 0 { vec_push(&lw.scratch, sp); }
    }
    n.kids = kids_from_scratch(lw, mark);
    if had_specs && n.kids.len == 0 && (n.flags & NF_STAR) == 0 { return; }
    vec_push(&lw.scratch, n);
}

// --- statement dispatch ------------------------------------------------------

private void emit_stmt(Lower* lw, Node* s) {
    if s == null { return; }
    i32 k = s.kind;
    if k == N_INTERFACE || k == N_TYPE_ALIAS { return; }
    if (s.flags & NF_DECLARE) != 0 { return; }
    if k == N_FUNCTION && (s.flags & NF_SIGNATURE) != 0 { return; }
    if k == N_ENUM { lower_enum(lw, s); return; }
    if k == N_NAMESPACE { lower_namespace(lw, s, ""); return; }
    if k == N_IMPORT { lower_import(lw, s); return; }
    if k == N_EXPORT { lower_export(lw, s); return; }
    Node* tmp = s;
    lower_slot(lw, &tmp);
    if tmp != null { vec_push(&lw.scratch, tmp); }
}

private void lower_stmt_list(Lower* lw, NodeList* list) {
    i32 mark = lw.scratch.len;
    for i32 i = 0; i < list.len; i++ {
        emit_stmt(lw, *(list.items + i));
    }
    *list = kids_from_scratch(lw, mark);
}

// Rewrites *slot in place; unwraps erasure-only wrappers.
private void lower_slot(Lower* lw, Node** slot) {
    Node* n = *slot;
    if n == null { return; }
    if n.kind == N_AS || n.kind == N_NONNULL {
        lower_slot(lw, &n.a);
        *slot = n.a;
        return;
    }
    if n.kind == N_BLOCK || n.kind == N_PROGRAM {
        lower_stmt_list(lw, &n.kids);
        return;
    }
    if n.kind == N_SWITCH {
        lower_slot(lw, &n.a);
        for i32 i = 0; i < n.kids.len; i++ {
            Node* c = *(n.kids.items + i);
            lower_slot(lw, &c.a);
            lower_stmt_list(lw, &c.kids);
        }
        return;
    }
    if n.kind == N_CLASS {
        lower_class(lw, n);
        return;
    }
    lower_slot(lw, &n.a);
    lower_slot(lw, &n.b);
    lower_slot(lw, &n.c);
    lower_slot(lw, &n.d);
    for i32 i = 0; i < n.kids.len; i++ {
        lower_slot(lw, n.kids.items + i);
    }
}

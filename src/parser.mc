// parser.mc — recursive-descent TS parser over the pull lexer.
//
// Types are parsed with a consume-only grammar (ts_* functions) and
// erased; enum/namespace/parameter-properties keep full AST for
// lowering. Ambiguities (arrows, call type arguments) parse
// speculatively: save state, mute diagnostics, attempt, commit or
// restore. See doc/PLAN_M3_parser.md.

import vec;
import diag;
import lexer;
import ast;
import bump;

type NodePtr = Node*;

struct Parser {
    Lexer lx;
    Token cur;
    i32 prev_end;
    i32 no_in;         // > 0 while parsing for-statement init
    DiagList* diags;
    Bump* arena;
    Vec<NodePtr> scratch;
}

struct PState {
    i32 lex_pos;
    Token cur;
    i32 prev_end;
    i32 scratch_len;
}

void parser_init(Parser* p, str src, DiagList* diags, Bump* arena) {
    lexer_init(&p.lx, src, diags);
    p.diags = diags;
    p.arena = arena;
    p.prev_end = 0;
    p.no_in = 0;
    vec_init<NodePtr>(&p.scratch, 64);
    p.cur = lexer_next(&p.lx);
}

void parser_destroy(Parser* p) {
    vec_free(&p.scratch);
    lexer_destroy(&p.lx);
}

// --- core helpers ---------------------------------------------------

private void advance(Parser* p) {
    p.prev_end = p.cur.end;
    p.cur = lexer_next(&p.lx);
}

private Token peek(Parser* p) {
    i32 save = lexer_tell(&p.lx);
    Token t = lexer_next(&p.lx);
    lexer_seek(&p.lx, save);
    return t;
}

private PState psave(Parser* p) {
    PState s;
    s.lex_pos = lexer_tell(&p.lx);
    s.cur = p.cur;
    s.prev_end = p.prev_end;
    s.scratch_len = p.scratch.len;
    return s;
}

private void prestore(Parser* p, PState s) {
    lexer_seek(&p.lx, s.lex_pos);
    p.cur = s.cur;
    p.prev_end = s.prev_end;
    p.scratch.len = s.scratch_len;
}

private bool at(Parser* p, i32 k) {
    return p.cur.kind == k;
}

private bool eat(Parser* p, i32 k) {
    if p.cur.kind == k {
        advance(p);
        return true;
    }
    return false;
}

private void perror(Parser* p, str msg) {
    diag_add(p.diags, DIAG_ERROR, Span{p.cur.start, p.cur.end}, msg);
}

private void expect(Parser* p, i32 k, str msg) {
    if p.cur.kind == k {
        advance(p);
        return;
    }
    perror(p, msg);
}

// ASI: a real ';', or a virtual one before '}', EOF, or a newline.
private void expect_semi(Parser* p) {
    if p.cur.kind == TOK_SEMI {
        advance(p);
        return;
    }
    if p.cur.kind == TOK_RBRACE || p.cur.kind == TOK_EOF { return; }
    if p.cur.newline_before { return; }
    perror(p, "expected ';'");
}

private Node* nnew(Parser* p, i32 kind) {
    Node* n = cast(Node*, bump_alloc(p.arena, cast(i32, sizeof(Node))));
    n.kind = kind;
    n.span.start = p.cur.start;
    n.span.end = p.cur.end;
    return n;
}

private Node* nfin(Parser* p, Node* n) {
    n.span.end = p.prev_end;
    return n;
}

private NodeList finish_kids(Parser* p, i32 mark) {
    NodeList l;
    l.len = p.scratch.len - mark;
    l.items = null;
    if l.len > 0 {
        l.items = cast(Node**, bump_alloc(p.arena, l.len * 8));
        for i32 i = 0; i < l.len; i++ {
            *(l.items + i) = vec_get(&p.scratch, mark + i);
        }
    }
    p.scratch.len = mark;
    return l;
}

private bool is_ident_like(i32 k) {
    return k == TOK_IDENT || tok_is_keyword(k);
}

// Contextual keywords that are valid identifiers in expression code.
private bool is_ctx_ident(i32 k) {
    return k == TOK_KW_ABSTRACT || k == TOK_KW_AS || k == TOK_KW_ASSERTS
        || k == TOK_KW_ASYNC || k == TOK_KW_DECLARE || k == TOK_KW_FROM
        || k == TOK_KW_GET || k == TOK_KW_GLOBAL || k == TOK_KW_INFER
        || k == TOK_KW_IS || k == TOK_KW_KEYOF || k == TOK_KW_MODULE
        || k == TOK_KW_NAMESPACE || k == TOK_KW_OF || k == TOK_KW_OUT
        || k == TOK_KW_OVERRIDE || k == TOK_KW_READONLY || k == TOK_KW_SATISFIES
        || k == TOK_KW_SET || k == TOK_KW_TYPE || k == TOK_KW_UNIQUE;
}

private bool is_binding_ident(i32 k) {
    return k == TOK_IDENT || is_ctx_ident(k);
}

// A genuine reserved word — invalid where the grammar needs an Identifier
// (BindingIdentifier / IdentifierReference) rather than an IdentifierName.
// yield/await are contextual (valid identifiers in sloppy code), so they
// are excluded here.
private bool is_reserved_word(i32 k) {
    return tok_is_keyword(k) && !is_ctx_ident(k)
        && k != TOK_KW_YIELD && k != TOK_KW_AWAIT;
}

private bool is_assign_op(i32 k) {
    return k == TOK_EQ || k == TOK_PLUS_EQ || k == TOK_MINUS_EQ
        || k == TOK_STAR_EQ || k == TOK_SLASH_EQ || k == TOK_PERCENT_EQ
        || k == TOK_STARSTAR_EQ || k == TOK_LSHIFT_EQ || k == TOK_RSHIFT_EQ
        || k == TOK_URSHIFT_EQ || k == TOK_AMP_EQ || k == TOK_PIPE_EQ
        || k == TOK_CARET_EQ || k == TOK_AMPAMP_EQ || k == TOK_PIPEPIPE_EQ
        || k == TOK_QUESTION_QUESTION_EQ;
}

// --- '<' and '>' splitting for type contexts --------------------------

private void split_lt(Parser* p) {
    i32 k = p.cur.kind;
    if k == TOK_LSHIFT || k == TOK_LSHIFT_EQ || k == TOK_LE {
        lexer_seek(&p.lx, p.cur.start + 1);
        p.prev_end = p.cur.start + 1;
        p.cur = lexer_next(&p.lx);
        return;
    }
    expect(p, TOK_LT, "expected '<'");
}

private void expect_gt(Parser* p) {
    i32 k = p.cur.kind;
    if k == TOK_GT {
        advance(p);
        return;
    }
    if k == TOK_RSHIFT || k == TOK_URSHIFT || k == TOK_GE
        || k == TOK_RSHIFT_EQ || k == TOK_URSHIFT_EQ {
        lexer_seek(&p.lx, p.cur.start + 1);
        p.prev_end = p.cur.start + 1;
        p.cur = lexer_next(&p.lx);
        return;
    }
    perror(p, "expected '>'");
}

// --- type grammar: parsed and discarded -------------------------------

// Balanced token consumption from an open delimiter, template-aware.
private void ts_balanced(Parser* p, i32 open, i32 close) {
    advance(p);
    i32 depth = 1;
    while depth > 0 {
        i32 k = p.cur.kind;
        if k == TOK_EOF {
            perror(p, "unexpected end of file in type");
            return;
        }
        if k == open { depth++; advance(p); continue; }
        if k == close { depth--; advance(p); continue; }
        if k == TOK_LPAREN { ts_balanced(p, TOK_LPAREN, TOK_RPAREN); continue; }
        if k == TOK_LBRACE { ts_balanced(p, TOK_LBRACE, TOK_RBRACE); continue; }
        if k == TOK_LBRACK { ts_balanced(p, TOK_LBRACK, TOK_RBRACK); continue; }
        if k == TOK_TEMPLATE_HEAD { ts_skip_template(p); continue; }
        advance(p);
    }
}

private void ts_skip_template(Parser* p) {
    advance(p);
    while true {
        while p.cur.kind != TOK_RBRACE {
            i32 k = p.cur.kind;
            if k == TOK_EOF { perror(p, "unterminated template"); return; }
            if k == TOK_LPAREN { ts_balanced(p, TOK_LPAREN, TOK_RPAREN); continue; }
            if k == TOK_LBRACE { ts_balanced(p, TOK_LBRACE, TOK_RBRACE); continue; }
            if k == TOK_LBRACK { ts_balanced(p, TOK_LBRACK, TOK_RBRACK); continue; }
            if k == TOK_TEMPLATE_HEAD { ts_skip_template(p); continue; }
            advance(p);
        }
        Token t = lexer_rescan_template(&p.lx, p.cur);
        p.cur = t;
        if t.kind == TOK_TEMPLATE_TAIL { advance(p); return; }
        if t.kind == TOK_TEMPLATE_MIDDLE { advance(p); continue; }
        return;   // TOK_ERROR; diagnostic already emitted
    }
}

private void ts_entity(Parser* p) {
    if is_ident_like(p.cur.kind) {
        advance(p);
    } else {
        perror(p, "expected type name");
        return;
    }
    while p.cur.kind == TOK_DOT {
        advance(p);
        if is_ident_like(p.cur.kind) {
            advance(p);
        } else {
            perror(p, "expected name after '.'");
            return;
        }
    }
}

private void ts_type_args(Parser* p) {
    split_lt(p);
    while true {
        ts_type(p);
        if eat(p, TOK_COMMA) { continue; }
        break;
    }
    expect_gt(p);
}

private void ts_type_params(Parser* p) {
    split_lt(p);
    while true {
        while (p.cur.kind == TOK_KW_CONST || p.cur.kind == TOK_KW_IN
                || p.cur.kind == TOK_KW_OUT) && is_ident_like(peek(p).kind) {
            advance(p);
        }
        if is_ident_like(p.cur.kind) {
            advance(p);
        } else {
            perror(p, "expected type parameter name");
            break;
        }
        if eat(p, TOK_KW_EXTENDS) { ts_type(p); }
        if eat(p, TOK_EQ) { ts_type(p); }
        if eat(p, TOK_COMMA) { continue; }
        break;
    }
    expect_gt(p);
}

private void ts_import_type(Parser* p) {
    advance(p);
    expect(p, TOK_LPAREN, "expected '(' after import");
    expect(p, TOK_STRING, "expected module string");
    expect(p, TOK_RPAREN, "expected ')'");
    while eat(p, TOK_DOT) {
        if is_ident_like(p.cur.kind) {
            advance(p);
        } else {
            perror(p, "expected name after '.'");
            break;
        }
    }
    if p.cur.kind == TOK_LT { ts_type_args(p); }
}

private void ts_function_type(Parser* p) {
    if p.cur.kind == TOK_LT { ts_type_params(p); }
    if p.cur.kind != TOK_LPAREN {
        perror(p, "expected '(' in function type");
        return;
    }
    ts_balanced(p, TOK_LPAREN, TOK_RPAREN);
    if eat(p, TOK_ARROW) { ts_type(p); }
}

private void ts_primary(Parser* p) {
    i32 k = p.cur.kind;
    if k == TOK_LPAREN || k == TOK_LT {
        ts_function_type(p);
        return;
    }
    if k == TOK_LBRACE { ts_balanced(p, TOK_LBRACE, TOK_RBRACE); return; }
    if k == TOK_LBRACK { ts_balanced(p, TOK_LBRACK, TOK_RBRACK); return; }
    if k == TOK_STRING || k == TOK_NUMBER || k == TOK_BIGINT {
        advance(p);
        return;
    }
    if k == TOK_MINUS {
        advance(p);
        if p.cur.kind == TOK_NUMBER || p.cur.kind == TOK_BIGINT {
            advance(p);
        } else {
            perror(p, "expected numeric literal");
        }
        return;
    }
    if k == TOK_TEMPLATE_FULL { advance(p); return; }
    if k == TOK_TEMPLATE_HEAD { ts_skip_template(p); return; }
    if k == TOK_KW_IMPORT { ts_import_type(p); return; }
    if k == TOK_KW_THIS { advance(p); return; }
    if is_ident_like(k) {
        ts_entity(p);
        if p.cur.kind == TOK_LT || p.cur.kind == TOK_LSHIFT { ts_type_args(p); }
        return;
    }
    perror(p, "expected type");
}

private void ts_prefix(Parser* p) {
    i32 k = p.cur.kind;
    if k == TOK_KW_KEYOF || k == TOK_KW_READONLY || k == TOK_KW_UNIQUE
        || k == TOK_KW_INFER {
        advance(p);
        ts_prefix(p);
        return;
    }
    if k == TOK_KW_TYPEOF {
        advance(p);
        if p.cur.kind == TOK_KW_IMPORT {
            ts_import_type(p);
        } else {
            ts_entity(p);
            if p.cur.kind == TOK_LT { ts_type_args(p); }
        }
        return;
    }
    if k == TOK_KW_NEW {
        advance(p);
        ts_function_type(p);
        return;
    }
    if k == TOK_KW_ABSTRACT && peek(p).kind == TOK_KW_NEW {
        advance(p);
        advance(p);
        ts_function_type(p);
        return;
    }
    ts_primary(p);
}

private void ts_postfix(Parser* p) {
    ts_prefix(p);
    while p.cur.kind == TOK_LBRACK && !p.cur.newline_before {
        advance(p);
        if p.cur.kind != TOK_RBRACK { ts_type(p); }
        expect(p, TOK_RBRACK, "expected ']'");
    }
}

private void ts_isect(Parser* p) {
    eat(p, TOK_AMP);
    ts_postfix(p);
    while eat(p, TOK_AMP) { ts_postfix(p); }
}

private void ts_union(Parser* p) {
    eat(p, TOK_PIPE);
    ts_isect(p);
    while eat(p, TOK_PIPE) { ts_isect(p); }
}

private void ts_type(Parser* p) {
    ts_union(p);
    while p.cur.kind == TOK_KW_EXTENDS {
        advance(p);
        ts_union(p);
        expect(p, TOK_QUESTION, "expected '?' in conditional type");
        ts_type(p);
        expect(p, TOK_COLON, "expected ':' in conditional type");
        ts_type(p);
    }
}

// After ':' in a return-type position: allows type predicates.
private void ts_return_type(Parser* p) {
    if p.cur.kind == TOK_KW_ASSERTS
        && (is_ident_like(peek(p).kind) || peek(p).kind == TOK_KW_THIS) {
        advance(p);
        advance(p);
        if eat(p, TOK_KW_IS) { ts_type(p); }
        return;
    }
    if (is_ident_like(p.cur.kind) || p.cur.kind == TOK_KW_THIS)
        && peek(p).kind == TOK_KW_IS {
        advance(p);
        advance(p);
        ts_type(p);
        return;
    }
    ts_type(p);
}

// --- bindings and parameters -----------------------------------------

private Node* prop_name(Parser* p) {
    i32 k = p.cur.kind;
    if is_ident_like(k) {
        Node* n = nnew(p, N_IDENT);
        n.name = p.cur.text;
        advance(p);
        return n;
    }
    if k == TOK_STRING {
        Node* n = nnew(p, N_STRING);
        n.name = p.cur.text;
        advance(p);
        return n;
    }
    if k == TOK_NUMBER {
        Node* n = nnew(p, N_NUMBER);
        n.num = p.cur.num;
        advance(p);
        return n;
    }
    perror(p, "expected property name");
    return nnew(p, N_ERROR);
}

private Node* parse_binding(Parser* p) {
    i32 k = p.cur.kind;
    if is_binding_ident(k) {
        Node* n = nnew(p, N_IDENT);
        n.name = p.cur.text;
        advance(p);
        return n;
    }
    if k == TOK_LBRACK {
        Node* n = nnew(p, N_ARRAY_PATTERN);
        advance(p);
        i32 mark = p.scratch.len;
        while !at(p, TOK_RBRACK) && !at(p, TOK_EOF) {
            if at(p, TOK_COMMA) {
                vec_push(&p.scratch, nnew(p, N_HOLE));
                advance(p);
                continue;
            }
            Node* el;
            if eat(p, TOK_DOTDOTDOT) {
                el = nnew(p, N_REST);
                el.a = parse_binding(p);
                // a rest element closes the pattern: it takes no default and
                // nothing may follow it, not even a trailing comma
                if at(p, TOK_EQ) {
                    perror(p, "a rest element cannot have a default");
                } else if !at(p, TOK_RBRACK) {
                    perror(p, "a rest element must be last");
                }
            } else {
                el = parse_binding(p);
                if eat(p, TOK_EQ) {
                    Node* ap = nnew(p, N_ASSIGN_PATTERN);
                    ap.a = el;
                    ap.b = parse_assign(p);
                    el = ap;
                }
            }
            vec_push(&p.scratch, el);
            if !eat(p, TOK_COMMA) { break; }
        }
        expect(p, TOK_RBRACK, "expected ']'");
        n.kids = finish_kids(p, mark);
        return nfin(p, n);
    }
    if k == TOK_LBRACE {
        Node* n = nnew(p, N_OBJECT_PATTERN);
        advance(p);
        i32 mark = p.scratch.len;
        while !at(p, TOK_RBRACE) && !at(p, TOK_EOF) {
            if eat(p, TOK_DOTDOTDOT) {
                Node* r = nnew(p, N_REST);
                r.a = parse_binding(p);
                vec_push(&p.scratch, r);
                // as in array patterns, a rest property ends the pattern
                if at(p, TOK_EQ) {
                    perror(p, "a rest property cannot have a default");
                } else if !at(p, TOK_RBRACE) {
                    perror(p, "a rest property must be last");
                }
                break;
            }
            Node* pp = nnew(p, N_PATTERN_PROP);
            if at(p, TOK_LBRACK) {
                advance(p);
                pp.a = parse_assign(p);
                expect(p, TOK_RBRACK, "expected ']'");
                pp.flags |= NF_COMPUTED;
                expect(p, TOK_COLON, "expected ':'");
                pp.b = parse_binding(p);
            } else {
                i32 keyk = p.cur.kind;
                pp.a = prop_name(p);
                if eat(p, TOK_COLON) {
                    pp.b = parse_binding(p);
                } else {
                    pp.flags |= NF_SHORTHAND;
                    // shorthand binds the key as an identifier
                    if is_reserved_word(keyk) { perror(p, "unexpected reserved word"); }
                    Node* t = nnew(p, N_IDENT);
                    t.name = pp.a.name;
                    pp.b = t;
                }
            }
            if eat(p, TOK_EQ) {
                Node* ap = nnew(p, N_ASSIGN_PATTERN);
                ap.a = pp.b;
                ap.b = parse_assign(p);
                pp.b = ap;
            }
            vec_push(&p.scratch, pp);
            if !eat(p, TOK_COMMA) { break; }
        }
        expect(p, TOK_RBRACE, "expected '}'");
        n.kids = finish_kids(p, mark);
        return nfin(p, n);
    }
    perror(p, "expected binding");
    return nnew(p, N_ERROR);
}

private bool starts_binding(Token t) {
    return is_binding_ident(t.kind) || t.kind == TOK_LBRACE || t.kind == TOK_LBRACK
        || t.kind == TOK_DOTDOTDOT;
}

// Parses '(' params ')' pushing N_PARAM nodes onto scratch.
private void parse_params_into(Parser* p) {
    expect(p, TOK_LPAREN, "expected '('");
    while !at(p, TOK_RPAREN) && !at(p, TOK_EOF) {
        if at(p, TOK_KW_THIS) {
            // type-only `this` parameter: consumed, no node
            advance(p);
            if eat(p, TOK_COLON) { ts_type(p); }
        } else {
            Node* prm = nnew(p, N_PARAM);
            while (p.cur.kind == TOK_KW_PUBLIC || p.cur.kind == TOK_KW_PRIVATE
                    || p.cur.kind == TOK_KW_PROTECTED || p.cur.kind == TOK_KW_READONLY
                    || p.cur.kind == TOK_KW_OVERRIDE) && starts_binding(peek(p)) {
                prm.flags |= NF_PARAM_PROP;
                advance(p);
            }
            if eat(p, TOK_DOTDOTDOT) { prm.flags |= NF_REST; }
            prm.a = parse_binding(p);
            if eat(p, TOK_QUESTION) { prm.flags |= NF_OPTIONAL; }
            if eat(p, TOK_COLON) { ts_type(p); }
            if eat(p, TOK_EQ) {
                if (prm.flags & NF_REST) != 0 {
                    perror(p, "a rest parameter cannot have a default");
                }
                prm.b = parse_assign(p);
            }
            vec_push(&p.scratch, nfin(p, prm));
        }
        if !eat(p, TOK_COMMA) { break; }
    }
    expect(p, TOK_RPAREN, "expected ')'");
}

// Type params, params, return type, then body or overload signature.
// `start` is where the whole form began (the `function` keyword, a method's
// name), which is what Function.prototype.toString hands back. -1 keeps the
// parameter list's own position.
private Node* parse_callable(Parser* p, i32 flags, i32 start) {
    Node* fun = nnew(p, N_FUNCTION);
    if start >= 0 { fun.span.start = start; }
    fun.flags = flags;
    if p.cur.kind == TOK_LT { ts_type_params(p); }
    i32 mark = p.scratch.len;
    parse_params_into(p);
    fun.kids = finish_kids(p, mark);
    if eat(p, TOK_COLON) { ts_return_type(p); }
    if at(p, TOK_LBRACE) {
        fun.a = parse_block(p);
    } else {
        fun.flags |= NF_SIGNATURE;
        expect_semi(p);
    }
    return nfin(p, fun);
}

// After the 'function' keyword; `start` is where that keyword was.
private Node* parse_function_rest(Parser* p, i32 flags, bool need_name, i32 start) {
    if eat(p, TOK_STAR) { flags |= NF_GENERATOR; }
    str name;
    name.data = null;
    name.len = 0;
    if is_binding_ident(p.cur.kind) {
        name = p.cur.text;
        advance(p);
    } else if need_name {
        perror(p, "expected function name");
    }
    Node* fun = parse_callable(p, flags, start);
    fun.name = name;
    return fun;
}

// --- expressions ------------------------------------------------------

private i32 bin_prec(i32 k) {
    if k == TOK_QUESTION_QUESTION || k == TOK_PIPEPIPE { return 1; }
    if k == TOK_AMPAMP { return 2; }
    if k == TOK_PIPE { return 3; }
    if k == TOK_CARET { return 4; }
    if k == TOK_AMP { return 5; }
    if k == TOK_EQEQ || k == TOK_NEQ || k == TOK_EQEQEQ || k == TOK_NEQEQEQ { return 6; }
    if k == TOK_LT || k == TOK_GT || k == TOK_LE || k == TOK_GE
        || k == TOK_KW_IN || k == TOK_KW_INSTANCEOF { return 7; }
    if k == TOK_LSHIFT || k == TOK_RSHIFT || k == TOK_URSHIFT { return 8; }
    if k == TOK_PLUS || k == TOK_MINUS { return 9; }
    if k == TOK_STAR || k == TOK_SLASH || k == TOK_PERCENT { return 10; }
    if k == TOK_STARSTAR { return 11; }
    return 0;
}

private Node* parse_template(Parser* p) {
    Node* t = nnew(p, N_TEMPLATE);
    i32 mark = p.scratch.len;
    Node* q = nnew(p, N_TEMPLATE_ELEM);
    q.name = p.cur.text;
    q.aux = p.cur.aux;   // raw quasi
    vec_push(&p.scratch, q);
    if at(p, TOK_TEMPLATE_FULL) {
        advance(p);
        t.kids = finish_kids(p, mark);
        return nfin(p, t);
    }
    advance(p);   // TEMPLATE_HEAD
    while true {
        vec_push(&p.scratch, parse_expression(p));
        if !at(p, TOK_RBRACE) {
            perror(p, "expected '}' in template");
            break;
        }
        Token tk = lexer_rescan_template(&p.lx, p.cur);
        p.cur = tk;
        if tk.kind == TOK_ERROR { break; }
        Node* e = nnew(p, N_TEMPLATE_ELEM);
        e.name = tk.text;
        e.aux = tk.aux;   // raw quasi
        vec_push(&p.scratch, e);
        advance(p);
        if tk.kind == TOK_TEMPLATE_TAIL { break; }
    }
    t.kids = finish_kids(p, mark);
    return nfin(p, t);
}

private Node* parse_object(Parser* p) {
    Node* o = nnew(p, N_OBJECT);
    advance(p);
    i32 mark = p.scratch.len;
    while !at(p, TOK_RBRACE) && !at(p, TOK_EOF) {
        if eat(p, TOK_DOTDOTDOT) {
            Node* s = nnew(p, N_SPREAD);
            s.a = parse_assign(p);
            vec_push(&p.scratch, nfin(p, s));
            if !eat(p, TOK_COMMA) { break; }
            continue;
        }
        Node* pr = nnew(p, N_PROP);
        i32 fnflags = 0;
        if (p.cur.kind == TOK_KW_GET || p.cur.kind == TOK_KW_SET
                || p.cur.kind == TOK_KW_ASYNC) && starts_member_name(peek(p)) {
            if p.cur.kind == TOK_KW_GET { pr.flags |= NF_GETTER; }
            if p.cur.kind == TOK_KW_SET { pr.flags |= NF_SETTER; }
            if p.cur.kind == TOK_KW_ASYNC { fnflags |= NF_ASYNC; }
            advance(p);
        }
        if eat(p, TOK_STAR) { fnflags |= NF_GENERATOR; }
        i32 keyk = TOK_IDENT;
        if at(p, TOK_LBRACK) {
            advance(p);
            pr.a = parse_assign(p);
            expect(p, TOK_RBRACK, "expected ']'");
            pr.flags |= NF_COMPUTED;
        } else {
            keyk = p.cur.kind;
            pr.a = prop_name(p);
        }
        if at(p, TOK_LPAREN) || at(p, TOK_LT) {
            // a method definition, unlike `key: function (...)`, requires
            // its parameter names to be unique
            pr.b = parse_callable(p, fnflags | NF_METHOD, pr.span.start);
        } else if eat(p, TOK_COLON) {
            pr.b = parse_assign(p);
        } else if eat(p, TOK_EQ) {
            // destructuring cover grammar: shorthand with default
            pr.flags |= NF_SHORTHAND;
            // shorthand key is an IdentifierReference — not a reserved word
            if is_reserved_word(keyk) { perror(p, "unexpected reserved word"); }
            pr.b = parse_assign(p);
        } else {
            pr.flags |= NF_SHORTHAND;
            if is_reserved_word(keyk) { perror(p, "unexpected reserved word"); }
        }
        vec_push(&p.scratch, nfin(p, pr));
        if !eat(p, TOK_COMMA) { break; }
    }
    expect(p, TOK_RBRACE, "expected '}'");
    o.kids = finish_kids(p, mark);
    return nfin(p, o);
}

private Node* parse_array(Parser* p) {
    Node* a = nnew(p, N_ARRAY);
    advance(p);
    i32 mark = p.scratch.len;
    while !at(p, TOK_RBRACK) && !at(p, TOK_EOF) {
        if at(p, TOK_COMMA) {
            vec_push(&p.scratch, nnew(p, N_HOLE));
            advance(p);
            continue;
        }
        if eat(p, TOK_DOTDOTDOT) {
            Node* s = nnew(p, N_SPREAD);
            s.a = parse_assign(p);
            vec_push(&p.scratch, nfin(p, s));
        } else {
            vec_push(&p.scratch, parse_assign(p));
        }
        if !eat(p, TOK_COMMA) { break; }
    }
    expect(p, TOK_RBRACK, "expected ']'");
    a.kids = finish_kids(p, mark);
    return nfin(p, a);
}

private Node* parse_primary(Parser* p) {
    i32 k = p.cur.kind;
    if k == TOK_NUMBER {
        Node* n = nnew(p, N_NUMBER);
        n.num = p.cur.num;
        advance(p);
        return n;
    }
    if k == TOK_STRING {
        Node* n = nnew(p, N_STRING);
        n.name = p.cur.text;
        advance(p);
        return n;
    }
    if k == TOK_BIGINT {
        Node* n = nnew(p, N_BIGINT);
        n.name = p.cur.text;
        advance(p);
        return n;
    }
    if k == TOK_KW_TRUE || k == TOK_KW_FALSE {
        Node* n = nnew(p, N_BOOL);
        n.name = p.cur.text;
        advance(p);
        return n;
    }
    if k == TOK_KW_NULL {
        Node* n = nnew(p, N_NULL);
        advance(p);
        return n;
    }
    if k == TOK_KW_THIS {
        Node* n = nnew(p, N_THIS);
        advance(p);
        return n;
    }
    if k == TOK_KW_SUPER {
        Node* n = nnew(p, N_SUPER);
        advance(p);
        return n;
    }
    // `async function` must be tested before the identifier case: `async` is a
    // contextual keyword, so the general branch below would swallow it and
    // leave `function` stranded.
    if k == TOK_KW_ASYNC && peek(p).kind == TOK_KW_FUNCTION && !peek(p).newline_before {
        i32 fstart = p.cur.start;
        advance(p);
        advance(p);
        return parse_function_rest(p, NF_ASYNC, false, fstart);
    }
    if k == TOK_IDENT || is_ctx_ident(k) {
        Node* n = nnew(p, N_IDENT);
        n.name = p.cur.text;
        advance(p);
        return n;
    }
    if k == TOK_PRIVATE_NAME {
        // `#x in obj`
        Node* n = nnew(p, N_PRIVATE_IDENT);
        n.name = p.cur.text;
        advance(p);
        return n;
    }
    if k == TOK_LBRACK { return parse_array(p); }
    if k == TOK_LBRACE { return parse_object(p); }
    if k == TOK_LPAREN {
        advance(p);
        Node* e = parse_expression(p);
        expect(p, TOK_RPAREN, "expected ')'");
        // parentheses end an optional chain: in `(a?.b).c` the outer access is
        // its own reference and runs even when the inner one short-circuited
        e.flags |= NF_PARENED;
        return e;
    }
    if k == TOK_TEMPLATE_FULL || k == TOK_TEMPLATE_HEAD {
        return parse_template(p);
    }
    if k == TOK_SLASH || k == TOK_SLASH_EQ {
        Token r = lexer_rescan_regex(&p.lx, p.cur);
        p.cur = r;
        Node* n = nnew(p, N_REGEX);
        n.name = r.text;
        n.aux = r.aux;
        advance(p);
        return n;
    }
    if k == TOK_KW_FUNCTION {
        i32 fstart = p.cur.start;
        advance(p);
        return parse_function_rest(p, 0, false, fstart);
    }
    if k == TOK_KW_CLASS { return parse_class(p, 0, false); }
    if k == TOK_KW_IMPORT {
        Node* n = nnew(p, N_IMPORT_EXPR);
        advance(p);
        if eat(p, TOK_DOT) {
            n.kind = N_IMPORT_META;
            if is_ident_like(p.cur.kind) {
                advance(p);
            } else {
                perror(p, "expected 'meta'");
            }
        }
        return nfin(p, n);
    }
    if k == TOK_AT {
        perror(p, "decorators are not supported");
        advance(p);
        return nnew(p, N_ERROR);
    }
    perror(p, "unexpected token");
    return nnew(p, N_ERROR);
}

private bool starts_member_name(Token t) {
    i32 k = t.kind;
    return k == TOK_IDENT || tok_is_keyword(k) || k == TOK_STRING || k == TOK_NUMBER
        || k == TOK_LBRACK || k == TOK_PRIVATE_NAME || k == TOK_STAR;
}

// Speculative `f<T>(x)` / `f<T>\`t\``: commit only when the argument
// list closes onto '(' or a template.
private bool try_type_args_call(Parser* p) {
    PState st = psave(p);
    i32 base = p.diags.n_suppressed;
    diags_mute(p.diags);
    split_lt(p);
    while true {
        ts_type(p);
        if eat(p, TOK_COMMA) { continue; }
        break;
    }
    expect_gt(p);
    bool ok = p.diags.n_suppressed == base
        && (p.cur.kind == TOK_LPAREN || p.cur.kind == TOK_TEMPLATE_FULL
            || p.cur.kind == TOK_TEMPLATE_HEAD);
    diags_unmute(p.diags);
    if !ok { prestore(p, st); }
    return ok;
}

private NodeList parse_args(Parser* p) {
    i32 mark = p.scratch.len;
    expect(p, TOK_LPAREN, "expected '('");
    while !at(p, TOK_RPAREN) && !at(p, TOK_EOF) {
        if eat(p, TOK_DOTDOTDOT) {
            Node* s = nnew(p, N_SPREAD);
            s.a = parse_assign(p);
            vec_push(&p.scratch, nfin(p, s));
        } else {
            vec_push(&p.scratch, parse_assign(p));
        }
        if !eat(p, TOK_COMMA) { break; }
    }
    expect(p, TOK_RPAREN, "expected ')'");
    return finish_kids(p, mark);
}

private Node* parse_member_name(Parser* p, Node* obj, i32 flags) {
    Node* m = nnew(p, N_MEMBER);
    m.span.start = obj.span.start;
    m.a = obj;
    m.flags = flags;
    if p.cur.kind == TOK_PRIVATE_NAME {
        m.flags |= NF_PRIVATE;
        m.name = p.cur.text;
        advance(p);
    } else if is_ident_like(p.cur.kind) {
        m.name = p.cur.text;
        advance(p);
    } else {
        perror(p, "expected property name");
    }
    return nfin(p, m);
}

private Node* parse_new(Parser* p) {
    Node* n = nnew(p, N_NEW);
    advance(p);
    if eat(p, TOK_DOT) {
        n.kind = N_NEW_TARGET;
        if is_ident_like(p.cur.kind) {
            advance(p);
        } else {
            perror(p, "expected 'target'");
        }
        return nfin(p, n);
    }
    n.a = parse_member_or_call(p, false);
    if p.cur.kind == TOK_LT { ignore try_type_args_call(p); }
    if at(p, TOK_LPAREN) { n.kids = parse_args(p); }
    return nfin(p, n);
}

private Node* parse_member_or_call(Parser* p, bool allow_call) {
    Node* e;
    if at(p, TOK_KW_NEW) {
        e = parse_new(p);
    } else {
        e = parse_primary(p);
    }
    while true {
        i32 k = p.cur.kind;
        if k == TOK_DOT {
            advance(p);
            e = parse_member_name(p, e, 0);
            continue;
        }
        if k == TOK_QUESTION_DOT {
            advance(p);
            if at(p, TOK_LPAREN) && allow_call {
                Node* c = nnew(p, N_CALL);
                c.span.start = e.span.start;
                c.a = e;
                c.flags = NF_OPT_CHAIN;
                c.kids = parse_args(p);
                e = nfin(p, c);
                continue;
            }
            if at(p, TOK_LBRACK) {
                advance(p);
                Node* ix = nnew(p, N_INDEX);
                ix.span.start = e.span.start;
                ix.a = e;
                ix.flags = NF_OPT_CHAIN;
                ix.b = parse_expression(p);
                expect(p, TOK_RBRACK, "expected ']'");
                e = nfin(p, ix);
                continue;
            }
            e = parse_member_name(p, e, NF_OPT_CHAIN);
            continue;
        }
        if k == TOK_LBRACK {
            advance(p);
            Node* ix = nnew(p, N_INDEX);
            ix.span.start = e.span.start;
            ix.a = e;
            ix.b = parse_expression(p);
            expect(p, TOK_RBRACK, "expected ']'");
            e = nfin(p, ix);
            continue;
        }
        if k == TOK_LPAREN && allow_call {
            Node* c = nnew(p, N_CALL);
            c.span.start = e.span.start;
            c.a = e;
            c.kids = parse_args(p);
            e = nfin(p, c);
            continue;
        }
        if (k == TOK_TEMPLATE_FULL || k == TOK_TEMPLATE_HEAD) && allow_call {
            Node* tt = nnew(p, N_TAGGED_TEMPLATE);
            tt.span.start = e.span.start;
            tt.a = e;
            tt.b = parse_template(p);
            e = nfin(p, tt);
            continue;
        }
        if k == TOK_BANG && !p.cur.newline_before {
            Node* nn = nnew(p, N_NONNULL);
            nn.span.start = e.span.start;
            nn.a = e;
            advance(p);
            e = nfin(p, nn);
            continue;
        }
        if k == TOK_LT && allow_call {
            if try_type_args_call(p) { continue; }
            break;
        }
        break;
    }
    return e;
}

private Node* parse_postfix(Parser* p) {
    Node* e = parse_member_or_call(p, true);
    if (p.cur.kind == TOK_PLUSPLUS || p.cur.kind == TOK_MINUSMINUS)
        && !p.cur.newline_before {
        Node* u = nnew(p, N_UPDATE);
        u.span.start = e.span.start;
        u.op = p.cur.kind;
        u.a = e;
        advance(p);
        return nfin(p, u);
    }
    return e;
}

private Node* parse_unary(Parser* p) {
    i32 k = p.cur.kind;
    if k == TOK_BANG || k == TOK_TILDE || k == TOK_PLUS || k == TOK_MINUS
        || k == TOK_KW_TYPEOF || k == TOK_KW_VOID || k == TOK_KW_DELETE {
        Node* u = nnew(p, N_UNARY);
        u.op = k;
        advance(p);
        u.a = parse_unary(p);
        return nfin(p, u);
    }
    if k == TOK_PLUSPLUS || k == TOK_MINUSMINUS {
        Node* u = nnew(p, N_UPDATE);
        u.op = k;
        u.flags = NF_PREFIX;
        advance(p);
        u.a = parse_unary(p);
        return nfin(p, u);
    }
    if k == TOK_KW_AWAIT {
        Node* u = nnew(p, N_AWAIT);
        advance(p);
        u.a = parse_unary(p);
        return nfin(p, u);
    }
    return parse_postfix(p);
}

private Node* parse_bin(Parser* p, i32 min_prec) {
    Node* left = parse_unary(p);
    while true {
        i32 k = p.cur.kind;
        if k == TOK_KW_AS || k == TOK_KW_SATISFIES {
            if min_prec > 7 { break; }
            advance(p);
            Node* w = nnew(p, N_AS);
            w.span.start = left.span.start;
            w.a = left;
            if k == TOK_KW_SATISFIES {
                w.flags |= NF_SATISFIES;
                ts_type(p);
            } else if at(p, TOK_KW_CONST) {
                advance(p);
                w.flags |= NF_CONST_ASSERT;
            } else {
                ts_type(p);
            }
            left = nfin(p, w);
            continue;
        }
        if k == TOK_KW_IN && p.no_in > 0 { break; }
        i32 pr = bin_prec(k);
        if pr == 0 || pr < min_prec { break; }
        advance(p);
        i32 next_min = pr + 1;
        if k == TOK_STARSTAR { next_min = pr; }
        Node* right = parse_bin(p, next_min);
        Node* b = nnew(p, N_BIN);
        b.span.start = left.span.start;
        b.op = k;
        b.a = left;
        b.b = right;
        left = nfin(p, b);
    }
    return left;
}

private Node* parse_cond(Parser* p) {
    Node* t = parse_bin(p, 1);
    if at(p, TOK_QUESTION) {
        Node* c = nnew(p, N_COND);
        c.span.start = t.span.start;
        advance(p);
        c.a = t;
        c.b = parse_assign(p);
        expect(p, TOK_COLON, "expected ':'");
        c.c = parse_assign(p);
        return nfin(p, c);
    }
    return t;
}

private Node* parse_yield(Parser* p) {
    Node* y = nnew(p, N_YIELD);
    advance(p);
    if at(p, TOK_STAR) {
        y.flags |= NF_DELEGATE;
        advance(p);
        y.a = parse_assign(p);
        return nfin(p, y);
    }
    i32 k = p.cur.kind;
    if !p.cur.newline_before && k != TOK_SEMI && k != TOK_RPAREN && k != TOK_RBRACK
        && k != TOK_RBRACE && k != TOK_COMMA && k != TOK_COLON && k != TOK_EOF {
        y.a = parse_assign(p);
    }
    return nfin(p, y);
}

// Arrow attempt from '(' or '<'. Returns null (state restored) if the
// tokens are not an arrow head.
private Node* try_arrow(Parser* p, i32 flags) {
    PState st = psave(p);
    i32 base = p.diags.n_suppressed;
    diags_mute(p.diags);
    i32 mark = p.scratch.len;
    i32 start = p.cur.start;
    if p.cur.kind == TOK_LT { ts_type_params(p); }
    bool ok = p.diags.n_suppressed == base && p.cur.kind == TOK_LPAREN;
    if ok {
        parse_params_into(p);
        if p.cur.kind == TOK_COLON && p.diags.n_suppressed == base {
            advance(p);
            ts_return_type(p);
        }
        ok = p.diags.n_suppressed == base && p.cur.kind == TOK_ARROW;
    }
    diags_unmute(p.diags);
    if !ok {
        prestore(p, st);
        return null;
    }
    Node* fun = nnew(p, N_FUNCTION);
    fun.span.start = start;
    fun.flags = NF_ARROW | flags;
    fun.kids = finish_kids(p, mark);
    advance(p);   // =>
    if at(p, TOK_LBRACE) {
        fun.a = parse_block(p);
    } else {
        fun.a = parse_assign(p);
    }
    return nfin(p, fun);
}

private Node* ident_arrow(Parser* p, i32 flags) {
    Node* fun = nnew(p, N_FUNCTION);
    fun.flags = NF_ARROW | flags;
    i32 mark = p.scratch.len;
    Node* prm = nnew(p, N_PARAM);
    Node* id = nnew(p, N_IDENT);
    id.name = p.cur.text;
    advance(p);
    prm.a = id;
    vec_push(&p.scratch, prm);
    fun.kids = finish_kids(p, mark);
    advance(p);   // =>
    if at(p, TOK_LBRACE) {
        fun.a = parse_block(p);
    } else {
        fun.a = parse_assign(p);
    }
    return nfin(p, fun);
}

Node* parse_assign(Parser* p) {
    i32 k = p.cur.kind;
    if k == TOK_KW_YIELD { return parse_yield(p); }
    if (k == TOK_IDENT || is_ctx_ident(k)) && peek(p).kind == TOK_ARROW {
        return ident_arrow(p, 0);
    }
    if k == TOK_KW_ASYNC && !peek(p).newline_before {
        Token pk = peek(p);
        // an async arrow reads from `async`, not from its parameter list
        i32 astart = p.cur.start;
        if (pk.kind == TOK_IDENT || is_ctx_ident(pk.kind)) && pk.kind != TOK_KW_ASYNC {
            PState st = psave(p);
            advance(p);
            if peek(p).kind == TOK_ARROW {
                Node* ar = ident_arrow(p, NF_ASYNC);
                ar.span.start = astart;
                return ar;
            }
            prestore(p, st);
        } else if pk.kind == TOK_LPAREN || pk.kind == TOK_LT {
            PState st = psave(p);
            advance(p);
            Node* ar = try_arrow(p, NF_ASYNC);
            if ar != null {
                ar.span.start = astart;
                return ar;
            }
            prestore(p, st);
        }
    }
    if k == TOK_LPAREN || k == TOK_LT {
        Node* ar = try_arrow(p, 0);
        if ar != null { return ar; }
    }
    Node* left = parse_cond(p);
    if is_assign_op(p.cur.kind) {
        Node* a = nnew(p, N_ASSIGN);
        a.span.start = left.span.start;
        a.op = p.cur.kind;
        advance(p);
        a.a = left;
        a.b = parse_assign(p);
        return nfin(p, a);
    }
    return left;
}

Node* parse_expression(Parser* p) {
    Node* e = parse_assign(p);
    if !at(p, TOK_COMMA) { return e; }
    Node* s = nnew(p, N_SEQ);
    s.span.start = e.span.start;
    i32 mark = p.scratch.len;
    vec_push(&p.scratch, e);
    while eat(p, TOK_COMMA) {
        vec_push(&p.scratch, parse_assign(p));
    }
    s.kids = finish_kids(p, mark);
    return nfin(p, s);
}

// --- statements -------------------------------------------------------

Node* parse_block(Parser* p) {
    Node* b = nnew(p, N_BLOCK);
    expect(p, TOK_LBRACE, "expected '{'");
    i32 mark = p.scratch.len;
    while !at(p, TOK_RBRACE) && !at(p, TOK_EOF) {
        i32 before = p.cur.start;
        Node* s = parse_statement(p);
        if s != null { vec_push(&p.scratch, s); }
        if p.cur.start == before && !at(p, TOK_RBRACE) && !at(p, TOK_EOF) {
            advance(p);
        }
    }
    expect(p, TOK_RBRACE, "expected '}'");
    b.kids = finish_kids(p, mark);
    return nfin(p, b);
}

private Node* parse_var_stmt(Parser* p) {
    Node* v = nnew(p, N_VAR);
    if p.cur.kind == TOK_KW_LET { v.flags |= NF_LET; }
    if p.cur.kind == TOK_KW_CONST { v.flags |= NF_CONST; }
    advance(p);
    i32 mark = p.scratch.len;
    while true {
        Node* d = nnew(p, N_DECLARATOR);
        d.a = parse_binding(p);
        if eat(p, TOK_BANG) { d.flags |= NF_DEFINITE; }
        if eat(p, TOK_COLON) { ts_type(p); }
        if eat(p, TOK_EQ) { d.b = parse_assign(p); }
        vec_push(&p.scratch, nfin(p, d));
        if !eat(p, TOK_COMMA) { break; }
    }
    v.kids = finish_kids(p, mark);
    expect_semi(p);
    return nfin(p, v);
}

private Node* parse_if(Parser* p) {
    Node* n = nnew(p, N_IF);
    advance(p);
    expect(p, TOK_LPAREN, "expected '('");
    n.a = parse_expression(p);
    expect(p, TOK_RPAREN, "expected ')'");
    n.b = parse_statement(p);
    if eat(p, TOK_KW_ELSE) { n.c = parse_statement(p); }
    return nfin(p, n);
}

private Node* parse_for(Parser* p) {
    i32 flags = 0;
    i32 start = p.cur.start;
    advance(p);
    if eat(p, TOK_KW_AWAIT) { flags |= NF_AWAIT; }
    expect(p, TOK_LPAREN, "expected '('");

    Node* init = null;
    if at(p, TOK_SEMI) {
        advance(p);
    } else if at(p, TOK_KW_VAR) || at(p, TOK_KW_LET) || at(p, TOK_KW_CONST) {
        Node* v = nnew(p, N_VAR);
        if p.cur.kind == TOK_KW_LET { v.flags |= NF_LET; }
        if p.cur.kind == TOK_KW_CONST { v.flags |= NF_CONST; }
        advance(p);
        i32 mark = p.scratch.len;
        Node* d = nnew(p, N_DECLARATOR);
        d.a = parse_binding(p);
        if eat(p, TOK_BANG) { d.flags |= NF_DEFINITE; }
        if eat(p, TOK_COLON) { ts_type(p); }
        if at(p, TOK_KW_OF) || at(p, TOK_KW_IN) {
            bool is_of = at(p, TOK_KW_OF);
            vec_push(&p.scratch, nfin(p, d));
            v.kids = finish_kids(p, mark);
            advance(p);
            Node* n = nnew(p, N_FOR_OF);
            if !is_of { n.kind = N_FOR_IN; }
            n.span.start = start;
            n.flags = flags;
            n.a = v;
            n.b = is_of ? parse_assign(p) : parse_expression(p);
            expect(p, TOK_RPAREN, "expected ')'");
            n.c = parse_statement(p);
            return nfin(p, n);
        }
        if eat(p, TOK_EQ) {
            p.no_in++;
            d.b = parse_assign(p);
            p.no_in--;
        }
        vec_push(&p.scratch, nfin(p, d));
        while eat(p, TOK_COMMA) {
            Node* d2 = nnew(p, N_DECLARATOR);
            d2.a = parse_binding(p);
            if eat(p, TOK_BANG) { d2.flags |= NF_DEFINITE; }
            if eat(p, TOK_COLON) { ts_type(p); }
            if eat(p, TOK_EQ) {
                p.no_in++;
                d2.b = parse_assign(p);
                p.no_in--;
            }
            vec_push(&p.scratch, nfin(p, d2));
        }
        v.kids = finish_kids(p, mark);
        init = nfin(p, v);
        expect(p, TOK_SEMI, "expected ';'");
    } else {
        p.no_in++;
        Node* e = parse_expression(p);
        p.no_in--;
        if at(p, TOK_KW_OF) || at(p, TOK_KW_IN) {
            bool is_of = at(p, TOK_KW_OF);
            advance(p);
            Node* n = nnew(p, is_of ? N_FOR_OF : N_FOR_IN);
            n.span.start = start;
            n.flags = flags;
            n.a = e;
            n.b = is_of ? parse_assign(p) : parse_expression(p);
            expect(p, TOK_RPAREN, "expected ')'");
            n.c = parse_statement(p);
            return nfin(p, n);
        }
        init = e;
        expect(p, TOK_SEMI, "expected ';'");
    }

    Node* n = nnew(p, N_FOR);
    n.span.start = start;
    n.flags = flags;
    n.a = init;
    if !at(p, TOK_SEMI) { n.b = parse_expression(p); }
    expect(p, TOK_SEMI, "expected ';'");
    if !at(p, TOK_RPAREN) { n.c = parse_expression(p); }
    expect(p, TOK_RPAREN, "expected ')'");
    n.d = parse_statement(p);
    return nfin(p, n);
}

private Node* parse_switch(Parser* p) {
    Node* n = nnew(p, N_SWITCH);
    advance(p);
    expect(p, TOK_LPAREN, "expected '('");
    n.a = parse_expression(p);
    expect(p, TOK_RPAREN, "expected ')'");
    expect(p, TOK_LBRACE, "expected '{'");
    i32 mark = p.scratch.len;
    while !at(p, TOK_RBRACE) && !at(p, TOK_EOF) {
        Node* c = nnew(p, N_CASE);
        if eat(p, TOK_KW_CASE) {
            c.a = parse_expression(p);
        } else if !eat(p, TOK_KW_DEFAULT) {
            perror(p, "expected 'case' or 'default'");
            break;
        }
        expect(p, TOK_COLON, "expected ':'");
        i32 cmark = p.scratch.len;
        while !at(p, TOK_KW_CASE) && !at(p, TOK_KW_DEFAULT) && !at(p, TOK_RBRACE)
            && !at(p, TOK_EOF) {
            i32 before = p.cur.start;
            Node* s = parse_statement(p);
            if s != null { vec_push(&p.scratch, s); }
            if p.cur.start == before && !at(p, TOK_RBRACE) && !at(p, TOK_EOF) {
                advance(p);
            }
        }
        c.kids = finish_kids(p, cmark);
        vec_push(&p.scratch, nfin(p, c));
    }
    expect(p, TOK_RBRACE, "expected '}'");
    n.kids = finish_kids(p, mark);
    return nfin(p, n);
}

private Node* parse_try(Parser* p) {
    Node* n = nnew(p, N_TRY);
    advance(p);
    n.a = parse_block(p);
    if at(p, TOK_KW_CATCH) {
        Node* c = nnew(p, N_CATCH);
        advance(p);
        if eat(p, TOK_LPAREN) {
            c.a = parse_binding(p);
            if eat(p, TOK_COLON) { ts_type(p); }
            expect(p, TOK_RPAREN, "expected ')'");
        }
        c.b = parse_block(p);
        n.b = nfin(p, c);
    }
    if eat(p, TOK_KW_FINALLY) { n.c = parse_block(p); }
    if n.b == null && n.c == null {
        perror(p, "expected 'catch' or 'finally'");
    }
    return nfin(p, n);
}

// --- classes ----------------------------------------------------------

private Node* parse_class_member(Parser* p) {
    if at(p, TOK_KW_STATIC) && peek(p).kind == TOK_LBRACE {
        Node* sb = nnew(p, N_STATIC_BLOCK);
        advance(p);
        sb.a = parse_block(p);
        return nfin(p, sb);
    }
    Node* m = nnew(p, N_CLASS_MEMBER);
    i32 fnflags = 0;
    // where the method's own text starts: at get/set/async if it has one,
    // else at the star or the name. `static` and the TypeScript modifiers
    // sit in front of that and are not part of it.
    i32 fstart = -1;
    while true {
        i32 k = p.cur.kind;
        i32 add = -1;
        if k == TOK_KW_STATIC { add = NF_STATIC; }
        else if k == TOK_KW_ASYNC { add = NF_ASYNC; }
        else if k == TOK_KW_GET { add = NF_GETTER; }
        else if k == TOK_KW_SET { add = NF_SETTER; }
        else if k == TOK_KW_ABSTRACT { add = NF_ABSTRACT; }
        else if k == TOK_KW_DECLARE { add = NF_DECLARE; }
        else if k == TOK_KW_READONLY || k == TOK_KW_PUBLIC || k == TOK_KW_PRIVATE
            || k == TOK_KW_PROTECTED || k == TOK_KW_OVERRIDE { add = 0; }
        if add < 0 { break; }
        if !starts_member_name(peek(p)) { break; }
        if fstart < 0 && (add == NF_ASYNC || add == NF_GETTER || add == NF_SETTER) {
            fstart = p.cur.start;
        }
        m.flags |= add;
        advance(p);
    }
    if fstart < 0 { fstart = p.cur.start; }
    if eat(p, TOK_STAR) { fnflags |= NF_GENERATOR; }
    if at(p, TOK_LBRACK) {
        // index signature: erased
        PState st = psave(p);
        advance(p);
        if is_ident_like(p.cur.kind) {
            advance(p);
            if at(p, TOK_COLON) {
                advance(p);
                ts_type(p);
                expect(p, TOK_RBRACK, "expected ']'");
                if eat(p, TOK_COLON) { ts_type(p); }
                expect_semi(p);
                return null;
            }
        }
        prestore(p, st);
        advance(p);
        m.a = parse_assign(p);
        expect(p, TOK_RBRACK, "expected ']'");
        m.flags |= NF_COMPUTED;
    } else if at(p, TOK_PRIVATE_NAME) {
        Node* pn = nnew(p, N_PRIVATE_IDENT);
        pn.name = p.cur.text;
        advance(p);
        m.a = pn;
    } else {
        m.a = prop_name(p);
    }
    if eat(p, TOK_QUESTION) { m.flags |= NF_OPTIONAL; }
    if eat(p, TOK_BANG) { m.flags |= NF_DEFINITE; }
    if at(p, TOK_LPAREN) || at(p, TOK_LT) {
        if (m.flags & NF_ASYNC) != 0 { fnflags |= NF_ASYNC; }
        if (m.flags & NF_GENERATOR) != 0 { fnflags |= NF_GENERATOR; }
        // NF_METHOD goes to the function, not the member: class and object
        // methods need unique parameter names
        m.b = parse_callable(p, fnflags | NF_METHOD, fstart);
        if fnflags != 0 { m.flags |= fnflags; }
        return nfin(p, m);
    }
    if fnflags != 0 { m.flags |= fnflags; }
    if eat(p, TOK_COLON) { ts_type(p); }
    if eat(p, TOK_EQ) { m.b = parse_assign(p); }
    expect_semi(p);
    return nfin(p, m);
}

private Node* parse_class(Parser* p, i32 flags, bool need_name) {
    Node* c = nnew(p, N_CLASS);
    c.flags = flags;
    advance(p);
    if is_binding_ident(p.cur.kind) {
        c.name = p.cur.text;
        advance(p);
    } else if need_name {
        perror(p, "expected class name");
    }
    if p.cur.kind == TOK_LT { ts_type_params(p); }
    if eat(p, TOK_KW_EXTENDS) {
        c.a = parse_member_or_call(p, true);
        if p.cur.kind == TOK_LT { ts_type_args(p); }
    }
    if eat(p, TOK_KW_IMPLEMENTS) {
        while true {
            ts_entity(p);
            if p.cur.kind == TOK_LT { ts_type_args(p); }
            if !eat(p, TOK_COMMA) { break; }
        }
    }
    expect(p, TOK_LBRACE, "expected '{'");
    i32 mark = p.scratch.len;
    while !at(p, TOK_RBRACE) && !at(p, TOK_EOF) {
        if eat(p, TOK_SEMI) { continue; }
        i32 before = p.cur.start;
        Node* m = parse_class_member(p);
        if m != null { vec_push(&p.scratch, m); }
        if p.cur.start == before && !at(p, TOK_RBRACE) && !at(p, TOK_EOF) {
            advance(p);
        }
    }
    expect(p, TOK_RBRACE, "expected '}'");
    c.kids = finish_kids(p, mark);
    return nfin(p, c);
}

// --- TS declarations ----------------------------------------------------

private Node* parse_enum(Parser* p, i32 flags) {
    Node* e = nnew(p, N_ENUM);
    e.flags = flags;
    advance(p);
    if is_binding_ident(p.cur.kind) {
        e.name = p.cur.text;
        advance(p);
    } else {
        perror(p, "expected enum name");
    }
    expect(p, TOK_LBRACE, "expected '{'");
    i32 mark = p.scratch.len;
    while !at(p, TOK_RBRACE) && !at(p, TOK_EOF) {
        Node* m = nnew(p, N_ENUM_MEMBER);
        if at(p, TOK_STRING) {
            Node* s = nnew(p, N_STRING);
            s.name = p.cur.text;
            advance(p);
            m.a = s;
        } else if is_ident_like(p.cur.kind) {
            Node* id = nnew(p, N_IDENT);
            id.name = p.cur.text;
            advance(p);
            m.a = id;
        } else {
            perror(p, "expected enum member name");
            break;
        }
        if eat(p, TOK_EQ) { m.b = parse_assign(p); }
        vec_push(&p.scratch, nfin(p, m));
        if !eat(p, TOK_COMMA) { break; }
    }
    expect(p, TOK_RBRACE, "expected '}'");
    e.kids = finish_kids(p, mark);
    return nfin(p, e);
}

private Node* parse_namespace_rest(Parser* p, i32 flags) {
    Node* n = nnew(p, N_NAMESPACE);
    n.flags = flags;
    if is_binding_ident(p.cur.kind) {
        n.name = p.cur.text;
        advance(p);
    } else {
        perror(p, "expected namespace name");
    }
    i32 mark = p.scratch.len;
    if eat(p, TOK_DOT) {
        Node* inner = parse_namespace_rest(p, flags);
        inner.flags |= NF_EXPORTED;
        vec_push(&p.scratch, inner);
        n.kids = finish_kids(p, mark);
        return nfin(p, n);
    }
    expect(p, TOK_LBRACE, "expected '{'");
    while !at(p, TOK_RBRACE) && !at(p, TOK_EOF) {
        i32 before = p.cur.start;
        Node* s = parse_statement(p);
        if s != null { vec_push(&p.scratch, s); }
        if p.cur.start == before && !at(p, TOK_RBRACE) && !at(p, TOK_EOF) {
            advance(p);
        }
    }
    expect(p, TOK_RBRACE, "expected '}'");
    n.kids = finish_kids(p, mark);
    return nfin(p, n);
}

private Node* parse_interface(Parser* p) {
    Node* n = nnew(p, N_INTERFACE);
    advance(p);
    if is_binding_ident(p.cur.kind) {
        n.name = p.cur.text;
        advance(p);
    } else {
        perror(p, "expected interface name");
    }
    if p.cur.kind == TOK_LT { ts_type_params(p); }
    if eat(p, TOK_KW_EXTENDS) {
        while true {
            ts_entity(p);
            if p.cur.kind == TOK_LT { ts_type_args(p); }
            if !eat(p, TOK_COMMA) { break; }
        }
    }
    if at(p, TOK_LBRACE) {
        ts_balanced(p, TOK_LBRACE, TOK_RBRACE);
    } else {
        perror(p, "expected '{'");
    }
    return nfin(p, n);
}

private Node* parse_type_alias(Parser* p) {
    Node* n = nnew(p, N_TYPE_ALIAS);
    advance(p);
    if is_binding_ident(p.cur.kind) {
        n.name = p.cur.text;
        advance(p);
    } else {
        perror(p, "expected type alias name");
    }
    if p.cur.kind == TOK_LT { ts_type_params(p); }
    expect(p, TOK_EQ, "expected '='");
    ts_type(p);
    expect_semi(p);
    return nfin(p, n);
}

private Node* parse_declare(Parser* p) {
    advance(p);
    if at(p, TOK_KW_GLOBAL) && peek(p).kind == TOK_LBRACE {
        Node* n = nnew(p, N_EMPTY);
        n.flags = NF_DECLARE;
        advance(p);
        ts_balanced(p, TOK_LBRACE, TOK_RBRACE);
        return nfin(p, n);
    }
    if at(p, TOK_KW_MODULE) && peek(p).kind == TOK_STRING {
        Node* n = nnew(p, N_EMPTY);
        n.flags = NF_DECLARE;
        advance(p);
        advance(p);
        if at(p, TOK_LBRACE) { ts_balanced(p, TOK_LBRACE, TOK_RBRACE); }
        return nfin(p, n);
    }
    Node* s = parse_statement(p);
    if s != null { s.flags |= NF_DECLARE; }
    return s;
}

// --- modules ------------------------------------------------------------

private Node* parse_import_decl(Parser* p) {
    Node* n = nnew(p, N_IMPORT);
    advance(p);
    if at(p, TOK_STRING) {
        n.name = p.cur.text;
        advance(p);
        expect_semi(p);
        return nfin(p, n);
    }
    if at(p, TOK_KW_TYPE) {
        Token pk = peek(p);
        if pk.kind == TOK_LBRACE || pk.kind == TOK_STAR
            || (is_binding_ident(pk.kind) && pk.kind != TOK_KW_FROM) {
            n.flags |= NF_TYPE_ONLY;
            advance(p);
        }
    }
    i32 mark = p.scratch.len;
    if is_binding_ident(p.cur.kind) {
        Node* d = nnew(p, N_IDENT);
        d.name = p.cur.text;
        advance(p);
        n.a = d;
        if !at(p, TOK_KW_FROM) { expect(p, TOK_COMMA, "expected ','"); }
    }
    if at(p, TOK_STAR) {
        advance(p);
        expect(p, TOK_KW_AS, "expected 'as'");
        Node* ns = nnew(p, N_IDENT);
        if is_binding_ident(p.cur.kind) {
            ns.name = p.cur.text;
            advance(p);
        } else {
            perror(p, "expected namespace alias");
        }
        n.b = ns;
    } else if at(p, TOK_LBRACE) {
        advance(p);
        while !at(p, TOK_RBRACE) && !at(p, TOK_EOF) {
            Node* sp = nnew(p, N_IMPORT_SPEC);
            if at(p, TOK_KW_TYPE) && (is_ident_like(peek(p).kind) || peek(p).kind == TOK_STRING) {
                sp.flags |= NF_TYPE_ONLY;
                advance(p);
            }
            if is_ident_like(p.cur.kind) || at(p, TOK_STRING) {
                sp.name = p.cur.text;
                advance(p);
            } else {
                perror(p, "expected import name");
                break;
            }
            Node* local = nnew(p, N_IDENT);
            local.name = sp.name;
            if eat(p, TOK_KW_AS) {
                if is_binding_ident(p.cur.kind) {
                    local.name = p.cur.text;
                    advance(p);
                } else {
                    perror(p, "expected local name");
                }
            }
            sp.a = local;
            vec_push(&p.scratch, nfin(p, sp));
            if !eat(p, TOK_COMMA) { break; }
        }
        expect(p, TOK_RBRACE, "expected '}'");
    }
    n.kids = finish_kids(p, mark);
    expect(p, TOK_KW_FROM, "expected 'from'");
    if at(p, TOK_STRING) {
        n.name = p.cur.text;
        advance(p);
    } else {
        perror(p, "expected module string");
    }
    if at(p, TOK_KW_WITH) && peek(p).kind == TOK_LBRACE {
        advance(p);
        ts_balanced(p, TOK_LBRACE, TOK_RBRACE);
    }
    expect_semi(p);
    return nfin(p, n);
}

private Node* parse_export_decl(Parser* p) {
    Node* n = nnew(p, N_EXPORT);
    advance(p);
    if at(p, TOK_EQ) {
        perror(p, "'export =' is not supported");
        advance(p);
        ignore parse_expression(p);
        expect_semi(p);
        return nfin(p, n);
    }
    if at(p, TOK_STAR) {
        n.flags |= NF_STAR;
        advance(p);
        if eat(p, TOK_KW_AS) {
            Node* ns = nnew(p, N_IDENT);
            if is_binding_ident(p.cur.kind) {
                ns.name = p.cur.text;
                advance(p);
            } else {
                perror(p, "expected alias");
            }
            n.b = ns;
        }
        expect(p, TOK_KW_FROM, "expected 'from'");
        if at(p, TOK_STRING) {
            n.name = p.cur.text;
            advance(p);
        } else {
            perror(p, "expected module string");
        }
        expect_semi(p);
        return nfin(p, n);
    }
    if at(p, TOK_KW_DEFAULT) {
        n.flags |= NF_DEFAULT;
        advance(p);
        if at(p, TOK_KW_FUNCTION) {
            i32 fstart = p.cur.start;
            advance(p);
            n.a = parse_function_rest(p, 0, false, fstart);
        } else if at(p, TOK_KW_ASYNC) && peek(p).kind == TOK_KW_FUNCTION {
            i32 fstart = p.cur.start;
            advance(p);
            advance(p);
            n.a = parse_function_rest(p, NF_ASYNC, false, fstart);
        } else if at(p, TOK_KW_CLASS) {
            n.a = parse_class(p, 0, false);
        } else if at(p, TOK_KW_ABSTRACT) && peek(p).kind == TOK_KW_CLASS {
            advance(p);
            n.a = parse_class(p, NF_ABSTRACT, false);
        } else {
            n.a = parse_assign(p);
            expect_semi(p);
        }
        return nfin(p, n);
    }
    bool type_only = false;
    if at(p, TOK_KW_TYPE) && peek(p).kind == TOK_LBRACE {
        type_only = true;
        n.flags |= NF_TYPE_ONLY;
        advance(p);
    }
    if at(p, TOK_LBRACE) {
        advance(p);
        i32 mark = p.scratch.len;
        while !at(p, TOK_RBRACE) && !at(p, TOK_EOF) {
            Node* sp = nnew(p, N_EXPORT_SPEC);
            if at(p, TOK_KW_TYPE) && !type_only && is_ident_like(peek(p).kind)
                && peek(p).kind != TOK_KW_AS {
                sp.flags |= NF_TYPE_ONLY;
                advance(p);
            }
            if is_ident_like(p.cur.kind) || at(p, TOK_STRING) {
                sp.name = p.cur.text;
                advance(p);
            } else {
                perror(p, "expected export name");
                break;
            }
            if eat(p, TOK_KW_AS) {
                Node* ex = nnew(p, N_IDENT);
                if is_ident_like(p.cur.kind) || at(p, TOK_STRING) {
                    ex.name = p.cur.text;
                    advance(p);
                } else {
                    perror(p, "expected exported name");
                }
                sp.a = ex;
            }
            vec_push(&p.scratch, nfin(p, sp));
            if !eat(p, TOK_COMMA) { break; }
        }
        expect(p, TOK_RBRACE, "expected '}'");
        n.kids = finish_kids(p, mark);
        if eat(p, TOK_KW_FROM) {
            if at(p, TOK_STRING) {
                n.name = p.cur.text;
                advance(p);
            } else {
                perror(p, "expected module string");
            }
        }
        expect_semi(p);
        return nfin(p, n);
    }
    n.a = parse_statement(p);
    return nfin(p, n);
}

// --- statement dispatch ---------------------------------------------------

Node* parse_statement(Parser* p) {
    i32 k = p.cur.kind;
    if k == TOK_LBRACE { return parse_block(p); }
    if k == TOK_SEMI {
        Node* n = nnew(p, N_EMPTY);
        advance(p);
        return nfin(p, n);
    }
    if k == TOK_KW_VAR || k == TOK_KW_LET { return parse_var_stmt(p); }
    if k == TOK_KW_CONST {
        if peek(p).kind == TOK_KW_ENUM {
            advance(p);
            return parse_enum(p, NF_CONST);
        }
        return parse_var_stmt(p);
    }
    if k == TOK_KW_FUNCTION {
        i32 fstart = p.cur.start;
        advance(p);
        return parse_function_rest(p, 0, true, fstart);
    }
    if k == TOK_KW_ASYNC && peek(p).kind == TOK_KW_FUNCTION && !peek(p).newline_before {
        i32 fstart = p.cur.start;
        advance(p);
        advance(p);
        return parse_function_rest(p, NF_ASYNC, true, fstart);
    }
    if k == TOK_KW_CLASS { return parse_class(p, 0, true); }
    if k == TOK_KW_ABSTRACT && peek(p).kind == TOK_KW_CLASS {
        advance(p);
        return parse_class(p, NF_ABSTRACT, true);
    }
    if k == TOK_KW_IF { return parse_if(p); }
    if k == TOK_KW_FOR { return parse_for(p); }
    if k == TOK_KW_WHILE {
        Node* n = nnew(p, N_WHILE);
        advance(p);
        expect(p, TOK_LPAREN, "expected '('");
        n.a = parse_expression(p);
        expect(p, TOK_RPAREN, "expected ')'");
        n.b = parse_statement(p);
        return nfin(p, n);
    }
    if k == TOK_KW_DO {
        Node* n = nnew(p, N_DO_WHILE);
        advance(p);
        n.a = parse_statement(p);
        expect(p, TOK_KW_WHILE, "expected 'while'");
        expect(p, TOK_LPAREN, "expected '('");
        n.b = parse_expression(p);
        expect(p, TOK_RPAREN, "expected ')'");
        eat(p, TOK_SEMI);
        return nfin(p, n);
    }
    if k == TOK_KW_RETURN {
        Node* n = nnew(p, N_RETURN);
        advance(p);
        if !p.cur.newline_before && !at(p, TOK_SEMI) && !at(p, TOK_RBRACE)
            && !at(p, TOK_EOF) {
            n.a = parse_expression(p);
        }
        expect_semi(p);
        return nfin(p, n);
    }
    if k == TOK_KW_BREAK || k == TOK_KW_CONTINUE {
        Node* n = nnew(p, k == TOK_KW_BREAK ? N_BREAK : N_CONTINUE);
        advance(p);
        if is_binding_ident(p.cur.kind) && !p.cur.newline_before {
            n.name = p.cur.text;
            advance(p);
        }
        expect_semi(p);
        return nfin(p, n);
    }
    if k == TOK_KW_THROW {
        Node* n = nnew(p, N_THROW);
        advance(p);
        if p.cur.newline_before {
            perror(p, "newline not allowed after 'throw'");
        }
        n.a = parse_expression(p);
        expect_semi(p);
        return nfin(p, n);
    }
    if k == TOK_KW_TRY { return parse_try(p); }
    if k == TOK_KW_SWITCH { return parse_switch(p); }
    if k == TOK_KW_DEBUGGER {
        Node* n = nnew(p, N_DEBUGGER);
        advance(p);
        expect_semi(p);
        return nfin(p, n);
    }
    if k == TOK_KW_ENUM { return parse_enum(p, 0); }
    if k == TOK_KW_INTERFACE && is_binding_ident(peek(p).kind) {
        return parse_interface(p);
    }
    if k == TOK_KW_TYPE && is_binding_ident(peek(p).kind) {
        return parse_type_alias(p);
    }
    if (k == TOK_KW_NAMESPACE || k == TOK_KW_MODULE) && is_binding_ident(peek(p).kind) {
        advance(p);
        return parse_namespace_rest(p, 0);
    }
    if k == TOK_KW_DECLARE {
        i32 pk = peek(p).kind;
        if pk == TOK_KW_VAR || pk == TOK_KW_LET || pk == TOK_KW_CONST
            || pk == TOK_KW_FUNCTION || pk == TOK_KW_CLASS || pk == TOK_KW_ENUM
            || pk == TOK_KW_NAMESPACE || pk == TOK_KW_MODULE || pk == TOK_KW_GLOBAL
            || pk == TOK_KW_INTERFACE || pk == TOK_KW_TYPE || pk == TOK_KW_ABSTRACT
            || pk == TOK_KW_ASYNC {
            return parse_declare(p);
        }
    }
    if k == TOK_KW_IMPORT {
        i32 pk = peek(p).kind;
        if pk != TOK_LPAREN && pk != TOK_DOT {
            return parse_import_decl(p);
        }
    }
    if k == TOK_KW_EXPORT { return parse_export_decl(p); }
    if k == TOK_AT {
        perror(p, "decorators are not supported");
        advance(p);
        ignore parse_member_or_call(p, true);
        return null;
    }
    // A label may be a plain identifier or a contextual keyword (e.g. the
    // `out` variance modifier, valid as an identifier outside type positions).
    if is_binding_ident(k) && peek(p).kind == TOK_COLON {
        Node* n = nnew(p, N_LABELED);
        n.name = p.cur.text;
        advance(p);
        advance(p);
        n.a = parse_statement(p);
        return nfin(p, n);
    }
    Node* n = nnew(p, N_EXPR_STMT);
    n.a = parse_expression(p);
    expect_semi(p);
    return nfin(p, n);
}

Node* parse_program(Parser* p) {
    Node* n = nnew(p, N_PROGRAM);
    i32 mark = p.scratch.len;
    while !at(p, TOK_EOF) {
        i32 before = p.cur.start;
        Node* s = parse_statement(p);
        if s != null { vec_push(&p.scratch, s); }
        if p.cur.start == before && !at(p, TOK_EOF) {
            advance(p);
        }
    }
    n.kids = finish_kids(p, mark);
    return nfin(p, n);
}

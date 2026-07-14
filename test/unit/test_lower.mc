// test_lower.mc — golden dumps of the lowered (plain ES) AST.

import str;
import "../helpers/check.mc";
import "../../src/diag.mc";
import "../../src/bump.mc";
import "../../src/ast.mc";
import "../../src/parser.mc";
import "../../src/lower.mc";

void check_lower(str src, str want, str what) {
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
    str_buf sb;
    str_buf_init(&sb);
    ast_dump(prog, &sb);
    str got = str_buf_to_str(&sb);
    bool same = str_equal(got, want);
    if !same {
        eprint("    got:  {}\n    want: {}\n", got, want);
    }
    check(same, what);
    check(d.n_errors == 0, what);
    str_buf_free(&sb);
    lower_destroy(&lw);
    parser_destroy(&p);
    bump_destroy(&arena);
    diags_free(&d);
}

void check_lower_error(str src, str what) {
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
    check(d.n_errors > 0, what);
    lower_destroy(&lw);
    parser_destroy(&p);
    bump_destroy(&arena);
    diags_free(&d);
}

i32 main() {
    // stripping
    check_lower("interface I { x: number; } type T = number; declare const q: number; let y = 1;",
        "(program (var:1 (declarator (ident y) (number 1.0))))",
        "type-only statements dropped");
    check_lower("const a = (b as T)!;",
        "(program (var:2 (declarator (ident a) (ident b))))",
        "as and nonnull unwrap");
    check_lower("f(x as any, y!);",
        "(program (expr-stmt (call (ident f) (ident x) (ident y))))",
        "unwrap inside args");
    check_lower("function f(a: number): void; function f(a) { return a; }",
        "(program (function f (block (return (ident a))) (param (ident a))))",
        "overload signature dropped");

    // type-only imports/exports
    check_lower("import type T from \"m\"; import { type U, v } from \"n\";",
        "(program (import n (import-spec v (ident v))))",
        "type-only imports filtered");
    check_lower("export type { T } from \"m\"; export { type U, w };",
        "(program (export (export-spec w)))",
        "type-only exports filtered");

    // parameter properties
    check_lower("class P { constructor(private x: number, y: string) {} }",
        "(program (class P (member (ident constructor) (function (block (expr-stmt (assign = (member-expr x (this)) (ident x)))) (param:16384 (ident x)) (param (ident y))))))",
        "param property assignment");
    check_lower("class D extends B { constructor(readonly r: number) { super(r); f(); } }",
        "(program (class D (ident B) (member (ident constructor) (function (block (expr-stmt (call (super) (ident r))) (expr-stmt (assign = (member-expr r (this)) (ident r))) (expr-stmt (call (ident f)))) (param:16384 (ident r))))))",
        "param property after super call");

    // abstract members dropped
    check_lower("abstract class C { abstract m(): void; x = 1; }",
        "(program (class:64 C (member (ident x) (number 1.0))))",
        "abstract member dropped");

    // enums
    check_lower("enum E { A, B = 5, C }",
        "(program (var (declarator (ident E))) (expr-stmt (call (function (block (expr-stmt (assign = (index (ident E) (assign = (index (ident E) (string A)) (number 0.0))) (string A))) (expr-stmt (assign = (index (ident E) (assign = (index (ident E) (string B)) (number 5.0))) (string B))) (expr-stmt (assign = (index (ident E) (assign = (index (ident E) (string C)) (number 6.0))) (string C)))) (param (ident E))) (bin || (ident E) (assign = (ident E) (object))))))",
        "numeric enum");
    check_lower("enum S { A = \"x\" }",
        "(program (var (declarator (ident S))) (expr-stmt (call (function (block (expr-stmt (assign = (index (ident S) (string A)) (string x)))) (param (ident S))) (bin || (ident S) (assign = (ident S) (object))))))",
        "string enum member");
    check_lower("enum F { A = 1, B = A << 2, C }",
        "(program (var (declarator (ident F))) (expr-stmt (call (function (block (expr-stmt (assign = (index (ident F) (assign = (index (ident F) (string A)) (number 1.0))) (string A))) (expr-stmt (assign = (index (ident F) (assign = (index (ident F) (string B)) (number 4.0))) (string B))) (expr-stmt (assign = (index (ident F) (assign = (index (ident F) (string C)) (number 5.0))) (string C)))) (param (ident F))) (bin || (ident F) (assign = (ident F) (object))))))",
        "enum constant folding");
    check_lower("export enum E { A }",
        "(program (export (var (declarator (ident E)))) (expr-stmt (call (function (block (expr-stmt (assign = (index (ident E) (assign = (index (ident E) (string A)) (number 0.0))) (string A)))) (param (ident E))) (bin || (ident E) (assign = (ident E) (object))))))",
        "export enum");
    check_lower_error("enum X { A = f(), B }", "auto increment after computed");

    // namespaces
    check_lower("namespace N { export const x = 1; const h = 2; }",
        "(program (var (declarator (ident N))) (expr-stmt (call (function (block (var:2 (declarator (ident x) (number 1.0))) (expr-stmt (assign = (member-expr x (ident N)) (ident x))) (var:2 (declarator (ident h) (number 2.0)))) (param (ident N))) (bin || (ident N) (assign = (ident N) (object))))))",
        "namespace with export");
    check_lower("namespace A.B { export function f() {} }",
        "(program (var (declarator (ident A))) (expr-stmt (call (function (block (var (declarator (ident B))) (expr-stmt (call (function (block (function f (block)) (expr-stmt (assign = (member-expr f (ident B)) (ident f)))) (param (ident B))) (assign = (ident B) (bin || (member-expr B (ident A)) (assign = (member-expr B (ident A)) (object))))))) (param (ident A))) (bin || (ident A) (assign = (ident A) (object))))))",
        "dotted namespace");

    return check_done("test_lower");
}

// test_parser.mc — golden AST dumps plus a broad no-error corpus.

import str;
import "../helpers/check.mc";
import "../../src/diag.mc";
import "../../src/bump.mc";
import "../../src/ast.mc";
import "../../src/parser.mc";

// Parses src, dumps the AST, compares. Also expects zero diagnostics.
void check_ast(str src, str want, str what) {
    DiagList d;
    diags_init(&d);
    Bump arena;
    bump_init(&arena);
    Parser p;
    parser_init(&p, src, &d, &arena);
    Node* prog = parse_program(&p);
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
    parser_destroy(&p);
    bump_destroy(&arena);
    diags_free(&d);
}

void check_parses(str src, str what) {
    DiagList d;
    diags_init(&d);
    Bump arena;
    bump_init(&arena);
    Parser p;
    parser_init(&p, src, &d, &arena);
    ignore parse_program(&p);
    if d.n_errors > 0 { diags_print(&d, "test", src); }
    check(d.n_errors == 0, what);
    parser_destroy(&p);
    bump_destroy(&arena);
    diags_free(&d);
}

void check_parse_error(str src, str what) {
    DiagList d;
    diags_init(&d);
    Bump arena;
    bump_init(&arena);
    Parser p;
    parser_init(&p, src, &d, &arena);
    ignore parse_program(&p);
    check(d.n_errors > 0, what);
    parser_destroy(&p);
    bump_destroy(&arena);
    diags_free(&d);
}

i32 main() {
    // declarations and literals
    check_ast("", "(program)", "empty program");
    check_ast("let x = 42;",
        "(program (var:1 (declarator (ident x) (number 42.0))))",
        "let decl");
    check_ast("const y = \"hi\";",
        "(program (var:2 (declarator (ident y) (string hi))))",
        "const decl");

    // precedence and associativity
    check_ast("1 + 2 * 3;",
        "(program (expr-stmt (bin + (number 1.0) (bin * (number 2.0) (number 3.0)))))",
        "mul binds tighter");
    check_ast("2 ** 3 ** 2;",
        "(program (expr-stmt (bin ** (number 2.0) (bin ** (number 3.0) (number 2.0)))))",
        "exponent right assoc");
    check_ast("a - b - c;",
        "(program (expr-stmt (bin - (bin - (ident a) (ident b)) (ident c))))",
        "minus left assoc");
    check_ast("a ?? b ? c : d;",
        "(program (expr-stmt (cond (bin ?? (ident a) (ident b)) (ident c) (ident d))))",
        "ternary over nullish");

    // members, calls, chains
    check_ast("a.b(1)[c];",
        "(program (expr-stmt (index (call (member-expr b (ident a)) (number 1.0)) (ident c))))",
        "member call index");
    check_ast("a?.b;",
        "(program (expr-stmt (member-expr:1024 b (ident a))))",
        "optional member");
    check_ast("new Foo(1);",
        "(program (expr-stmt (new (ident Foo) (number 1.0))))",
        "new with args");
    check_ast("/ab/g.test(s);",
        "(program (expr-stmt (call (member-expr test (regex ab)) (ident s))))",
        "regex primary");

    // arrows
    check_ast("x => x + 1;",
        "(program (expr-stmt (function:128 (bin + (ident x) (number 1.0)) (param (ident x)))))",
        "ident arrow");
    check_ast("(a: number, b?: string): void => a;",
        "(program (expr-stmt (function:128 (ident a) (param (ident a)) (param:256 (ident b)))))",
        "typed arrow erased");
    check_ast("async (x) => x;",
        "(program (expr-stmt (function:132 (ident x) (param (ident x)))))",
        "async arrow");

    // generics vs relational
    check_ast("f<number>(1);",
        "(program (expr-stmt (call (ident f) (number 1.0))))",
        "call type args erased");
    check_ast("a < b;",
        "(program (expr-stmt (bin < (ident a) (ident b))))",
        "relational stays");

    // templates
    check_ast("`a${x}b`;",
        "(program (expr-stmt (template (quasi a) (ident x) (quasi b))))",
        "template");

    // statements
    check_ast("if (a) b; else c;",
        "(program (if (ident a) (expr-stmt (ident b)) (expr-stmt (ident c))))",
        "if else");
    check_ast("for (const x of xs) {}",
        "(program (for-of (var:2 (declarator (ident x))) (ident xs) (block)))",
        "for of");
    check_ast("try { f(); } catch (e) { g(); } finally { h(); }",
        "(program (try (block (expr-stmt (call (ident f)))) (catch (ident e) (block (expr-stmt (call (ident g))))) (block (expr-stmt (call (ident h))))))",
        "try catch finally");

    // ASI
    check_ast("a\nb",
        "(program (expr-stmt (ident a)) (expr-stmt (ident b)))",
        "asi splits statements");
    check_ast("function f() { return\nx; }",
        "(program (function f (block (return) (expr-stmt (ident x)))))",
        "restricted return");

    // functions and generators
    check_ast("function* g() { yield 1; yield* h(); }",
        "(program (function:8 g (block (expr-stmt (yield (number 1.0))) (expr-stmt (yield:262144 (call (ident h)))))))",
        "generator and yield");

    // classes
    check_ast("class A extends B { x = 1; static m() {} get y() { return 1; } #p = 2; constructor(private z: number) {} }",
        "(program (class A (ident B) (member (ident x) (number 1.0)) (member:16 (ident m) (function (block))) (member:2048 (ident y) (function (block (return (number 1.0))))) (member (private-ident p) (number 2.0)) (member (ident constructor) (function (block) (param:16384 (ident z))))))",
        "class members");

    // TS runtime constructs keep full AST
    check_ast("enum E { A, B = 2, \"c\" = 3 }",
        "(program (enum E (enum-member (ident A)) (enum-member (ident B) (number 2.0)) (enum-member (string c) (number 3.0))))",
        "enum");
    check_ast("const enum F { X }",
        "(program (enum:2 F (enum-member (ident X))))",
        "const enum");
    check_ast("namespace A.B { export const x = 1; }",
        "(program (namespace A (namespace:134217728 B (export (var:2 (declarator (ident x) (number 1.0)))))))",
        "nested namespace");

    // TS erased constructs
    check_ast("interface I { x: number; m(): void; }",
        "(program (interface I))",
        "interface erased");
    check_ast("type T = string | number;",
        "(program (type-alias T))",
        "type alias erased");
    check_ast("declare function f(x: number): void;",
        "(program (function:32800 f (param (ident x))))",
        "declare function");
    check_ast("x as const;",
        "(program (expr-stmt (as:2097152 (ident x))))",
        "as const");
    check_ast("x!;",
        "(program (expr-stmt (nonnull (ident x))))",
        "non-null");
    check_ast("x satisfies T;",
        "(program (expr-stmt (as:4194304 (ident x))))",
        "satisfies");

    // destructuring
    check_ast("const {a, b: [c] = [1]} = o;",
        "(program (var:2 (declarator (object-pattern (pattern-prop:1048576 (ident a) (ident a)) (pattern-prop (ident b) (assign-pattern (array-pattern (ident c)) (array (number 1.0))))) (ident o))))",
        "destructuring decl");

    // modules
    check_ast("import d, { a, b as c } from \"m\";",
        "(program (import m (ident d) (import-spec a (ident a)) (import-spec b (ident c))))",
        "import decl");
    check_ast("import type T from \"m\";",
        "(program (import:65536 m (ident T)))",
        "type-only import");
    check_ast("export const k = 1;",
        "(program (export (var:2 (declarator (ident k) (number 1.0)))))",
        "export decl");
    check_ast("export default 42;",
        "(program (export:8388608 (number 42.0)))",
        "export default");
    check_ast("export { x as y } from \"m\";",
        "(program (export m (export-spec x (ident y))))",
        "re-export");
    check_ast("export * from \"m\";",
        "(program (export:16777216 m))",
        "star export");

    // broad corpus: must parse without diagnostics
    check_parses("let x: Array<Array<number>> = [];", "nested type args split >>");
    check_parses("type C<T> = T extends string ? 1 : 2;", "conditional type");
    check_parses("const m = new Map<string, number[]>();", "new with type args");
    check_parses("for await (const c of chunks) process(c);", "for await");
    check_parses("class Q<T> implements I<T>, J { readonly k?: T; static s = 0; async *gen(): AsyncGenerator<T> { yield* this.items; } }", "generic class");
    check_parses("const o = { a, b: 2, [k]: 3, m() { return 1; }, get g() { return 2; }, ...rest };", "object literal forms");
    check_parses("label: for (;;) { break label; }", "labels");
    check_parses("import.meta.url;", "import meta");
    check_parses("import(\"./m\").then(f);", "dynamic import");
    check_parses("declare module \"fs\" { export function readFileSync(p: string): Buffer; }", "ambient module");
    check_parses("declare global { interface Window { x: number; } }", "declare global");
    check_parses("const t = `a${1 + 2}${`nested${x}`}end`;", "nested templates");
    check_parses("switch (x) { case 1: case 2: f(); break; default: g(); }", "switch");
    check_parses("a?.b?.[c]?.(d);", "full optional chain");
    check_parses("x ??= y; a ||= b; c &&= d;", "logical assignment");
    check_parses("async function main(): Promise<void> { await Promise.all(ps.map(async (p) => p * 2)); }", "async await");
    check_parses("const arr = [1, , 2, ...rest];", "array holes and spread");
    check_parses("do { i++; } while (i < 10);", "do while");
    check_parses("class A { static { init(); } }", "static block");
    check_parses("obj = { async m() {}, *gen() {}, async *ag() {} };", "object methods");
    check_parses("type Fn = (a: number, b?: string) => void;", "function type");
    check_parses("let big: `hello ${string}` = `hello world`;", "template literal type");
    check_parses("function h(this: Window, ...args: number[]): void {}", "this param and rest");
    check_parses("tag`x${1}y`;", "tagged template");
    check_parses("new.target;", "new target");
    check_parses("enum Dir { Up = 1, Down = Up + 1 }", "enum with exprs");
    check_parses("function f(a: number): void; function f(a: string): void; function f(a) {}", "overloads");
    check_parses("export type { T } from \"m\";", "export type");
    check_parses("interface J extends K<string>, L {}", "interface extends");
    check_parses("const fn = function named() { return named; };", "named function expr");
    check_parses("throw new Error(\"boom\");", "throw");
    check_parses("delete obj.key; void 0; typeof x;", "unary keywords");
    check_parses("if (#field in obj) {}", "private in");

    // error cases: diagnostic without hanging
    check_parse_error("export = foo;", "export assign rejected");
    check_parse_error("@dec class A {}", "decorators rejected");
    check_parse_error("let 5 = x;", "bad binding");
    check_parse_error("123n;", "bigint rejected");
    check_parse_error("let x = ;", "missing initializer expr");

    return check_done("test_parser");
}

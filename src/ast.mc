// ast.mc — AST node types and the S-expression dumper.
//
// One Node struct for every kind: `kind` selects meaning, `op` holds
// an operator token kind, `a..d` are fixed child slots, `kids` a
// list. Nodes live in a bump arena owned by the caller.

import str;
import diag;
import lexer;

enum NodeKind {
    N_ERROR,
    N_PROGRAM,

    // statements and declarations
    N_VAR,            // kids: declarators; flags NF_LET/NF_CONST
    N_DECLARATOR,     // a: pattern, b: init
    N_EXPR_STMT,      // a
    N_BLOCK,          // kids
    N_EMPTY,
    N_IF,             // a: cond, b: then, c: else
    N_FOR,            // a: init, b: cond, c: update, d: body
    N_FOR_IN,         // a: left, b: right, c: body
    N_FOR_OF,         // a: left, b: right, c: body; NF_AWAIT for-await
    N_WHILE,          // a: cond, b: body
    N_DO_WHILE,       // a: body, b: cond
    N_RETURN,         // a: value?
    N_BREAK,          // name: label?
    N_CONTINUE,       // name: label?
    N_THROW,          // a
    N_TRY,            // a: block, b: catch, c: finally
    N_CATCH,          // a: param?, b: block
    N_SWITCH,         // a: disc, kids: cases
    N_CASE,           // a: test (null = default), kids: stmts
    N_LABELED,        // name, a: stmt
    N_DEBUGGER,
    N_FUNCTION,       // name?, kids: params, a: body (block/expr)
    N_PARAM,          // a: pattern, b: default?
    N_CLASS,          // name?, a: extends?, kids: members
    N_CLASS_MEMBER,   // a: key, b: value (function/init)
    N_STATIC_BLOCK,   // a: block
    N_ENUM,           // name, kids: members; NF_CONST for const enum
    N_ENUM_MEMBER,    // a: key, b: init?
    N_NAMESPACE,      // name, kids: body
    N_TYPE_ALIAS,     // name only; erased
    N_INTERFACE,      // name only; erased
    N_IMPORT,         // name: source, a: default?, b: ns alias?, kids: specs
    N_IMPORT_SPEC,    // name: imported, a: local ident
    N_EXPORT,         // a: decl/expr, b: ns alias, name: source?, kids: specs
    N_EXPORT_SPEC,    // name: local, a: exported ident

    // expressions
    N_IDENT,          // name
    N_PRIVATE_IDENT,  // name (without #)
    N_NUMBER,         // num
    N_STRING,         // name: value
    N_BIGINT,         // name: raw text
    N_REGEX,          // name: pattern, aux: flags
    N_BOOL,           // name: true/false
    N_NULL,
    N_THIS,
    N_SUPER,
    N_ARRAY,          // kids
    N_OBJECT,         // kids: props
    N_PROP,           // a: key, b: value?
    N_HOLE,
    N_SPREAD,         // a
    N_TEMPLATE,       // kids: elems and exprs interleaved
    N_TEMPLATE_ELEM,  // name: cooked
    N_TAGGED_TEMPLATE,// a: tag, b: template
    N_BIN,            // op, a, b
    N_ASSIGN,         // op, a, b
    N_COND,           // a: test, b: cons, c: alt
    N_UNARY,          // op, a
    N_UPDATE,         // op, a; NF_PREFIX
    N_CALL,           // a: callee, kids: args
    N_NEW,            // a: callee, kids: args
    N_MEMBER,         // a: obj, name: prop
    N_INDEX,          // a: obj, b: expr
    N_SEQ,            // kids
    N_YIELD,          // a?; NF_DELEGATE
    N_AWAIT,          // a
    N_NONNULL,        // a; TS x!
    N_AS,             // a; TS as/satisfies, erased; NF_CONST_ASSERT
    N_IMPORT_EXPR,    // dynamic import callee
    N_IMPORT_META,
    N_NEW_TARGET,

    // binding patterns
    N_ARRAY_PATTERN,  // kids
    N_OBJECT_PATTERN, // kids
    N_PATTERN_PROP,   // a: key, b: binding
    N_REST,           // a
    N_ASSIGN_PATTERN  // a: target, b: default
}

const i32 NF_LET = 1;
const i32 NF_CONST = 2;
const i32 NF_ASYNC = 4;
const i32 NF_GENERATOR = 8;
const i32 NF_STATIC = 16;
const i32 NF_DECLARE = 32;
const i32 NF_ABSTRACT = 64;
const i32 NF_ARROW = 128;
const i32 NF_OPTIONAL = 256;
const i32 NF_COMPUTED = 512;
const i32 NF_OPT_CHAIN = 1024;
const i32 NF_GETTER = 2048;
const i32 NF_SETTER = 4096;
const i32 NF_REST = 8192;
const i32 NF_PARAM_PROP = 16384;
const i32 NF_SIGNATURE = 32768;     // function overload signature, no body
const i32 NF_TYPE_ONLY = 65536;     // import/export type
const i32 NF_PREFIX = 131072;
const i32 NF_DELEGATE = 262144;     // yield*
const i32 NF_AWAIT = 524288;        // for await
const i32 NF_SHORTHAND = 1048576;
const i32 NF_CONST_ASSERT = 2097152; // as const
const i32 NF_SATISFIES = 4194304;
const i32 NF_DEFAULT = 8388608;     // export default
const i32 NF_STAR = 16777216;       // export *
const i32 NF_DEFINITE = 33554432;   // x!: definite assignment
const i32 NF_PRIVATE = 67108864;    // #name member access
const i32 NF_EXPORTED = 134217728;  // dotted-inner namespace
const i32 NF_METHOD = 268435456;    // method definition: parameters must be unique
const i32 NF_PARENED = 536870912;   // was written in parentheses: ends an optional chain

struct NodeList {
    Node** items;
    i32 len;
}

struct Node {
    i32 kind;
    i32 flags;
    i32 op;         // operator token kind
    Span span;
    str name;
    str aux;        // regex flags
    f64 num;
    Node* a;
    Node* b;
    Node* c;
    Node* d;
    NodeList kids;
}

str node_kind_name(i32 kind) {
    switch kind {
        case N_ERROR: { return "error"; }
        case N_PROGRAM: { return "program"; }
        case N_VAR: { return "var"; }
        case N_DECLARATOR: { return "declarator"; }
        case N_EXPR_STMT: { return "expr-stmt"; }
        case N_BLOCK: { return "block"; }
        case N_EMPTY: { return "empty"; }
        case N_IF: { return "if"; }
        case N_FOR: { return "for"; }
        case N_FOR_IN: { return "for-in"; }
        case N_FOR_OF: { return "for-of"; }
        case N_WHILE: { return "while"; }
        case N_DO_WHILE: { return "do-while"; }
        case N_RETURN: { return "return"; }
        case N_BREAK: { return "break"; }
        case N_CONTINUE: { return "continue"; }
        case N_THROW: { return "throw"; }
        case N_TRY: { return "try"; }
        case N_CATCH: { return "catch"; }
        case N_SWITCH: { return "switch"; }
        case N_CASE: { return "case"; }
        case N_LABELED: { return "labeled"; }
        case N_DEBUGGER: { return "debugger"; }
        case N_FUNCTION: { return "function"; }
        case N_PARAM: { return "param"; }
        case N_CLASS: { return "class"; }
        case N_CLASS_MEMBER: { return "member"; }
        case N_STATIC_BLOCK: { return "static-block"; }
        case N_ENUM: { return "enum"; }
        case N_ENUM_MEMBER: { return "enum-member"; }
        case N_NAMESPACE: { return "namespace"; }
        case N_TYPE_ALIAS: { return "type-alias"; }
        case N_INTERFACE: { return "interface"; }
        case N_IMPORT: { return "import"; }
        case N_IMPORT_SPEC: { return "import-spec"; }
        case N_EXPORT: { return "export"; }
        case N_EXPORT_SPEC: { return "export-spec"; }
        case N_IDENT: { return "ident"; }
        case N_PRIVATE_IDENT: { return "private-ident"; }
        case N_NUMBER: { return "number"; }
        case N_STRING: { return "string"; }
        case N_BIGINT: { return "bigint"; }
        case N_REGEX: { return "regex"; }
        case N_BOOL: { return "bool"; }
        case N_NULL: { return "null"; }
        case N_THIS: { return "this"; }
        case N_SUPER: { return "super"; }
        case N_ARRAY: { return "array"; }
        case N_OBJECT: { return "object"; }
        case N_PROP: { return "prop"; }
        case N_HOLE: { return "hole"; }
        case N_SPREAD: { return "spread"; }
        case N_TEMPLATE: { return "template"; }
        case N_TEMPLATE_ELEM: { return "quasi"; }
        case N_TAGGED_TEMPLATE: { return "tagged"; }
        case N_BIN: { return "bin"; }
        case N_ASSIGN: { return "assign"; }
        case N_COND: { return "cond"; }
        case N_UNARY: { return "unary"; }
        case N_UPDATE: { return "update"; }
        case N_CALL: { return "call"; }
        case N_NEW: { return "new"; }
        case N_MEMBER: { return "member-expr"; }
        case N_INDEX: { return "index"; }
        case N_SEQ: { return "seq"; }
        case N_YIELD: { return "yield"; }
        case N_AWAIT: { return "await"; }
        case N_NONNULL: { return "nonnull"; }
        case N_AS: { return "as"; }
        case N_IMPORT_EXPR: { return "import-expr"; }
        case N_IMPORT_META: { return "import-meta"; }
        case N_NEW_TARGET: { return "new-target"; }
        case N_ARRAY_PATTERN: { return "array-pattern"; }
        case N_OBJECT_PATTERN: { return "object-pattern"; }
        case N_PATTERN_PROP: { return "pattern-prop"; }
        case N_REST: { return "rest"; }
        case N_ASSIGN_PATTERN: { return "assign-pattern"; }
        default: { return "unknown"; }
    }
}

private str op_name(i32 op) {
    switch op {
        case TOK_PLUS: { return "+"; }
        case TOK_MINUS: { return "-"; }
        case TOK_STAR: { return "*"; }
        case TOK_SLASH: { return "/"; }
        case TOK_PERCENT: { return "%"; }
        case TOK_STARSTAR: { return "**"; }
        case TOK_EQEQ: { return "=="; }
        case TOK_NEQ: { return "!="; }
        case TOK_EQEQEQ: { return "==="; }
        case TOK_NEQEQEQ: { return "!=="; }
        case TOK_LT: { return "<"; }
        case TOK_GT: { return ">"; }
        case TOK_LE: { return "<="; }
        case TOK_GE: { return ">="; }
        case TOK_LSHIFT: { return "<<"; }
        case TOK_RSHIFT: { return ">>"; }
        case TOK_URSHIFT: { return ">>>"; }
        case TOK_AMP: { return "&"; }
        case TOK_PIPE: { return "|"; }
        case TOK_CARET: { return "^"; }
        case TOK_AMPAMP: { return "&&"; }
        case TOK_PIPEPIPE: { return "||"; }
        case TOK_QUESTION_QUESTION: { return "??"; }
        case TOK_EQ: { return "="; }
        case TOK_PLUS_EQ: { return "+="; }
        case TOK_MINUS_EQ: { return "-="; }
        case TOK_STAR_EQ: { return "*="; }
        case TOK_SLASH_EQ: { return "/="; }
        case TOK_PERCENT_EQ: { return "%="; }
        case TOK_STARSTAR_EQ: { return "**="; }
        case TOK_LSHIFT_EQ: { return "<<="; }
        case TOK_RSHIFT_EQ: { return ">>="; }
        case TOK_URSHIFT_EQ: { return ">>>="; }
        case TOK_AMP_EQ: { return "&="; }
        case TOK_PIPE_EQ: { return "|="; }
        case TOK_CARET_EQ: { return "^="; }
        case TOK_AMPAMP_EQ: { return "&&="; }
        case TOK_PIPEPIPE_EQ: { return "||="; }
        case TOK_QUESTION_QUESTION_EQ: { return "??="; }
        case TOK_BANG: { return "!"; }
        case TOK_TILDE: { return "~"; }
        case TOK_PLUSPLUS: { return "++"; }
        case TOK_MINUSMINUS: { return "--"; }
        case TOK_KW_TYPEOF: { return "typeof"; }
        case TOK_KW_VOID: { return "void"; }
        case TOK_KW_DELETE: { return "delete"; }
        case TOK_KW_IN: { return "in"; }
        case TOK_KW_INSTANCEOF: { return "instanceof"; }
        default: { return "?"; }
    }
}

// Compact S-expression dump: (kind[:flags] [op] [name] [num] a b c d kids...)
void ast_dump(Node* n, str_buf* sb) {
    str_buf_add(sb, "(");
    str_buf_add(sb, node_kind_name(n.kind));
    if n.flags != 0 {
        str_buf_add(sb, ":");
        string f = format("{}", n.flags);
        str_buf_add(sb, f);
        free(f);
    }
    if n.op != 0 {
        str_buf_add(sb, " ");
        str_buf_add(sb, op_name(n.op));
    }
    if n.name.len > 0 {
        str_buf_add(sb, " ");
        str_buf_add(sb, n.name);
    }
    if n.kind == N_NUMBER {
        str_buf_add(sb, " ");
        string v = format("{}", n.num);
        str_buf_add(sb, v);
        free(v);
    }
    if n.a != null { str_buf_add(sb, " "); ast_dump(n.a, sb); }
    if n.b != null { str_buf_add(sb, " "); ast_dump(n.b, sb); }
    if n.c != null { str_buf_add(sb, " "); ast_dump(n.c, sb); }
    if n.d != null { str_buf_add(sb, " "); ast_dump(n.d, sb); }
    for i32 i = 0; i < n.kids.len; i++ {
        str_buf_add(sb, " ");
        ast_dump(*(n.kids.items + i), sb);
    }
    str_buf_add(sb, ")");
}

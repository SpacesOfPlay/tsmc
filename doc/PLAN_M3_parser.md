# M3 — parser

Recursive-descent parser for the TS grammar, driving the M2 pull
lexer. Deliverables: `src/bump.mc`, `src/ast.mc`, `src/parser.mc`,
`test/unit/test_parser.mc`.

## AST shape

One `Node` struct: `kind` enum + `flags` + `op` (operator token kind) +
`span` + `name`/`num` payloads + four child slots + a `kids` list.
Nodes come from a growable bump arena (`bump.mc`), freed wholesale
after compilation. Child lists collect in a shared scratch vector and
copy into arena arrays (`kids`). A generic S-expression dumper
(`ast_dump`) drives the tests.

## Types are parsed, not kept

Type annotations must be parsed to be erased — generics vs `<`,
conditional types, object types with template-literal members. A
consume-only type grammar (`ts_*` functions) walks them and builds
nothing: union/intersection/conditional structure, operator prefixes,
function and constructor types, qualified names with type arguments,
and balanced consumption inside `{…}` `[…]` `(…)` with template-chain
awareness. `>`-family tokens split one `>` at a time via
`lexer_seek(tok.start + 1)`.

## Speculation

Arrow functions, call type arguments (`f<T>(x)`), and similar
ambiguities parse speculatively: save `{lexer pos, current token,
scratch length}`, mute diagnostics, attempt, and commit or restore.
`DiagList` gains a `muted` counter plus `n_suppressed`, so an attempt
detects its own errors without emitting them. `f<T>(x)` commits only
when the argument list closes onto `(` or a template — the same rule
TS uses.

## Coverage

- Expressions: full ES operator set with correct precedence and
  associativity, optional chains, `new`/`new.target`, tagged
  templates, regex via rescan, `import()` / `import.meta`, yield /
  await, TS `as` / `satisfies` / non-null `!` (erasure-shaped nodes).
- Statements: blocks, var/let/const with binding patterns, if, all
  for-forms (incl. `for await`), while/do, switch, try/catch/finally,
  labels, break/continue with labels, throw, debugger, ASI per spec
  including restricted productions.
- Declarations: functions (async/generator/overload signatures),
  classes (fields, methods, accessors, static, `#private`, computed
  names, static blocks, parameter properties), enums (incl. `const
  enum`), namespaces, interfaces and type aliases (name-only nodes),
  `declare` ambients, import/export in all forms with type-only
  flags.
- Errors: `export =`, decorators, and bigint values get clear
  diagnostics; recovery keeps the statement loop progressing.

## Deliberate M3 simplifications

- Assignment destructuring (`[a, b] = c`) keeps its literal-shaped
  LHS; the compiler milestone interprets it. Binding patterns in
  declarations and params are parsed structurally.
- No JSX/TSX, no angle-bracket type assertions (`as` only).
- Grammar is looser than spec where it only admits invalid programs
  (contextual keyword placement, strict-mode name rules); tightening
  rides on later conformance work.

## Tests

Golden S-expression dumps for core shapes (precedence, associativity,
chains, arrows, classes, patterns, modules, erasure results), plus a
broad TS corpus snippet that must parse with zero diagnostics.

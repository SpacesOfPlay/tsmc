# M5 — VM core

First executing milestone: `tsmc hello.ts` works and the golden run
tier activates. Design context: `DESIGN_bytecode.md`, `DESIGN_gc.md`.

## Deliverables

| Module | Contents |
|--------|----------|
| `src/object.mc` | Runtime cells: objects (with array part), functions, natives, boxes; property tables (atom→Value) with prototype chains; GC trace/finalize hooks |
| `src/bytecode.mc` | Opcode set, chunk writer, `FnTemplate` |
| `src/compiler.mc` | Lowered AST → bytecode; scope analysis per DESIGN_bytecode |
| `src/vm.mc` | Dispatch loop, frames, exceptions, coercions, console, pipeline entry (`vm_run_source`) |

GC changes: pluggable trace/finalize hooks for kinds the heap doesn't
know (objects own property tables and element arrays — a finalizer
switch replaces the "no destructors" rule, noted in DESIGN_gc), plus
a mark-roots hook the VM uses for stack, frames, globals, and
template constants.

## Semantics in scope

Literals, arithmetic with JS coercions (`+` string concat, ToNumber,
ToInt32 bit ops, `%` as fmod, `**`), `==`/`===` (object-vs-primitive
loose equality deferred with ToPrimitive), truthiness, typeof,
in/instanceof/delete, strings as immutable UTF-8 byte strings
(UTF-16 semantics arrive with DESIGN_string in M6), objects/arrays/
member/index access, functions/closures/recursion, `this`/`new`/
prototypes, if/while/do/for/switch, break/continue, ternary/logical/
sequence, template literals (via string concat), try/catch/finally/
throw with Error-shaped `{name, message}` objects, `console.log`/
`console.error`.

Top-level code runs as a script frame; undeclared assignment creates
a global. Uncaught exceptions print `Uncaught <name>: <message>` and
exit 1; compile diagnostics print and exit 2.

## Deferred with compile-time "not supported yet" diagnostics

Destructuring, spread, optional chaining, classes, getters/setters,
labeled statements, for-in/for-of, generators/async, regex, modules,
tagged templates, `new.target`, private members, logical assignment
to members. Known deviations, tracked for later milestones:
per-iteration `let` loop bindings compile as a single binding;
ToPrimitive on objects is not called (ToNumber(object) is NaN,
ToString(object) is "[object Object]", arrays join).

## Tests

`test/unit/test_vm.mc` drives snippets through the full pipeline with
a `probe(v)` native recording values — arithmetic, closures, capture
sharing, hoisting, TDZ, control flow, objects, prototypes, coercions,
exceptions. Golden run tests land in `test/run/`: hello, closures,
fib, prototype methods, try/catch/finally, coercions.

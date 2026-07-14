# M7 — modern syntax surface

Clears most remaining "not supported yet" diagnostics. Everything
compiles in `compiler.mc` against a handful of new opcodes; no AST
pre-lowering.

## Classes

Compiled directly: the constructor becomes a function template (a
synthesized empty one — or `(...a) { super(...a); }` for derived
classes — when the body has none), instance field initializers inject
into the constructor after the `super()` call, methods/accessors/
static members attach to `ctor.prototype`/`ctor` at class-creation
time. `extends` stores the parent in a hidden `%super` binding
(always a box; the `%` prefix cannot collide with user names).
`C.prototype` is a fresh object whose proto links the parent's via
`OP_SETPROTO`; `constructor` back-references. `super(...)` compiles
as `%super`-call with the current `this`; `super.m(args)` as
`%super.prototype.m` called with the current `this` — no runtime
helpers, plain call convention. Deferred: `#private` members,
`new.target`, static method inheritance (statics do not walk to the
parent), `this` inside static field initializers.

## Accessor properties

New cell kind `GC_ACCESSOR` (getter + setter Values).
`OP_DEFGETTER`/`OP_DEFSETTER` define or merge them. Property reads
resolve accessors at the VM ops (getter called with the receiver);
writes walk the prototype chain for a setter before creating an own
property. `Object.values/entries/assign` and `JSON.stringify` invoke
getters. Known simplification: `super.x` reads through an accessor
with the prototype as receiver.

## Destructuring

Compile-time desugar, shared between declarations, parameters, catch
bindings, and assignment expressions (the parser's cover-grammar
literals reinterpret as targets). Array patterns read by index
(arrays and strings; general iterables arrive with the iterator
protocol in M8); object patterns read by key; defaults compile as
undefined-checks; rest elements use `OP_ARR_SLICE_FROM`, object rest
`OP_OBJ_REST` with a compile-time excluded-key list.

## Spread and rest

Array literals and calls with spread build an args/element array
(`OP_ARR_APPEND`/`OP_ARR_SPREAD`) and dispatch via
`OP_CALL_ARRAY`/`OP_NEW_ARRAY`; object spread copies own properties
(`OP_OBJ_SPREAD`). Rest parameters: templates carry `has_rest`; the
call protocol collects surplus arguments into an array bound to the
last parameter slot.

## Optional chaining

A chain with any `?.` link compiles with a shared nil-exit: each
optional link tests its base (`OP_JUMP_NULLISH`, and a two-slot
variant for `fn?.()` after method extraction); the exit pushes
undefined for the entire chain, matching short-circuit semantics.

## Loops and labels

`for-of` over arrays and strings (index-based; `OP_CHECK_ITERABLE`
rejects other operands); `for-in` snapshots own enumerable keys
(`OP_KEYS`) and iterates the strings, skipping nullish operands.
Both support pattern bindings. Labeled statements and labeled
break/continue ride the existing loop-context stack. The M5
deviation on per-iteration `let` bindings is fixed: captured
`for-let` variables get a fresh box each iteration, so loop closures
capture distinct values.

## Deferred to M8

Symbols and the real iterator protocol (they need generators to be
useful), async/await. Still later: regex literals (M9), modules
(M10), `#private`, decorators.

## Tests

Probe suites: classes (fields, inheritance, super chains, accessors,
statics), destructuring in every position, spread/rest, optional
chains, for-of/for-in, labels, loop-closure capture. Golden runs:
classes.ts, destructure.ts. GC stress rerun over the class/spread
paths.

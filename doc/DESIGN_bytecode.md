# Bytecode and execution

Decision: **stack-based bytecode**, compiled per function into a
`FnTemplate`, executed by a dispatch-loop VM.

## Templates and chunks

A function compiles to a `FnTemplate`: code bytes, a constant pool of
Values, an upvalue capture spec, child templates, and frame metadata
(`n_params`, `n_slots`). Templates are plain allocations owned by the
VM for its lifetime; their constants are GC roots. Opcodes are one
byte; operands are little-endian u16 (constant index, slot, jump
target). Jumps are absolute within the chunk.

## Frames and calls

The value stack holds NaN-boxed Values. A frame is `{ function,
return ip, stack base, this, ctor flag }`. Call convention: caller
pushes `fn`, `this`, then args; `OP_CALL argc` builds the frame with
params in the first slots, missing args filled with undefined.
`OP_RETURN` collapses to the base and pushes the result. `OP_NEW`
creates the instance from `fn.prototype`, runs the call with the ctor
flag, and keeps the instance unless the body returned an object.
Method calls use `OP_GETMETHOD`, which pushes `fn` then the receiver,
evaluating the object expression once.

## Scope analysis (fused with compilation)

Per function, before emitting:

1. **Inner-name scan**: every identifier (and `this`) mentioned
   anywhere inside nested functions, transitively. A binding whose
   name is in this set becomes a **cell** — a GC box holding the
   value — stored in its frame slot. Over-approximation by name is
   deliberate: shadowing only costs an extra box, never correctness.
2. **Hoisting**: `var` declarators (stopping at nested functions)
   get function-level slots, undefined at entry. Function
   declarations bind and initialize at block entry, so mutual
   recursion works.
3. **Emission** with a block-scoped binding stack. `let`/`const`
   slots (or cells) hold the `hole` value until their declarator
   runs; reads compile to checked ops that throw ReferenceError on
   hole — TDZ. Slots are reused after block exit; closures captured
   the cell pointer, not the slot.

Identifier resolution walks: local bindings → enclosing functions
(adding an upvalue chain entry per level; the inner-name rule
guarantees the source binding is a cell) → global by atom.
`OP_CLOSURE` copies cell pointers out of the creating frame's slots
or its own upvalues, per the template's capture spec. Arrows have no
own `this`; non-arrow functions materialize a `this` binding only
when some inner arrow mentions it, and arrows resolve it like any
captured variable.

## Exceptions

A handler stack of `{ frame count, stack depth, catch ip }`.
`OP_TRY_PUSH`/`OP_TRY_POP` bracket protected regions; a throw pops
frames and stack to the innermost handler and pushes the exception
at its catch ip. `finally` compiles by inlining the block on the
normal path and on an exception path that rethrows; `return`,
`break`, and `continue` that cross a `finally` inline it before
jumping.

## Numbers

The i32 payload of the Value representation is the fast path:
arithmetic stays integral while operands and results fit, overflow
falls back to f64. `-0` always lives as f64. ToInt32 for bit ops
truncates through i64 (exact for |v| < 2^63; conformance work
revisits the extreme tail).

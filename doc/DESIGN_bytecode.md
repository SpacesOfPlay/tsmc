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

1. **Inner-name scan**: every name free in a nested function,
   transitively: mentioned in it, or free in a function nested in
   it, and bound by none of its own scopes (its parameters, vars,
   lets, catch parameters, class names; `this` and `arguments` in a
   non-arrow). Name-level at the declaring function: shadowing within
   it only costs an extra box, never correctness. A binding whose
   name is in the set is captured, and one of two ways. It is a
   **cell** — a GC box holding the value — stored in its frame slot,
   when a closure could see more than one value in it: it is assigned
   anywhere after its initialization (the scan flags the stores,
   including those in nested functions), declared more than once, a
   var initialized inside a loop, or captured by a function
   declaration, which is made at scope entry before the declaration
   runs. Otherwise it is **captured by value**: `OP_CLOSURE` copies
   the value itself into the closure's upvalue and the nested
   function reads it with `OP_GETUPVALV`, which refuses a hole. A
   parameter, `this`, `arguments`, `new.target`, a catch parameter
   and a for-in/of binding are by value even under function
   declarations, since they are set before those are made; a var, let,
   const or class only for function expressions written after its
   declarator. A lazily compiled function's body is scanned at the
   token level: its parameters, its `var`-declared names outside the
   functions nested in it and the keys before a colon are left out,
   a name before an assignment operator, `++` or `--`, or between a
   for's `(` and `in`/`of` is a store, and a `]` or `}` before `=`
   makes every name in the body a store.
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
(adding an upvalue chain entry per level, which carries whether the
source binding is a cell or a value) → global by atom.
`OP_CLOSURE` copies cell pointers, or values, out of the creating
frame's slots or its own upvalues, per the template's capture spec.

A for-of and an array destructuring open their iterator with
`OP_GET_ITER_S done`: over a plain array (its own prototype
Array.prototype, no own Symbol.iterator, the prototype's still the
built-in) the array stays on the stack as its own iterator and the
done slot holds the index as an int; `OP_ITER_NEXT_S`, `OP_ITER_STEP`
and `OP_ITER_REST` step it without an iterator object or a result,
and `OP_ITER_CLOSE` has nothing to return. A Map or Set whose
prototype still has the built-in iterator is stepped the same way, the
slot holding the sequence number of the entry returned last (-1 before
the first) and the map a hint of the slot after it, so a compaction
between steps loses no place; a Map yields a fresh [key, value] pair.
Any other iterable goes through the protocol with the slot a bool, as
before. `{}.name`
compiles to `OP_PROTOGET`, Object.prototype's data property without
the object; an accessor or a miss makes the object after all. Arrows have no
own `this`; non-arrow functions materialize a `this` binding only
when some inner arrow mentions it, and arrows resolve it like any
captured variable.

## Fused instructions

The emitter folds the pairs the bytecode profile of a real page shows
most, so that a dispatch and the stack traffic between them go. The
fold happens as the second instruction is about to be written: when
the one before it is whole, nothing jumps to the boundary between them
(`max_target` says what has been patched so far) and its opcode is the
expected one, the first is rewritten in place and the second never
written (`ch_op`, `ch_op_u16` in bytecode.mc; `emit_jumpf`,
`emit_jumpt`, `emit_getprop`, `emit_getindex` in compiler.mc). The
pairs: a store and the pop after it (`PUTLOCAL`, `SETPROP_POP`,
`SETUPVAL_POP`, `SETCELL_POP`); a load and the `undefined` a plain call
pushes as `this` (`GETLOCAL_UNDEF`, `GETUPVAL_UNDEF`,
`GETUPVALV_UNDEF`); a function's `undefined; return` (`RETURN_UNDEF`);
a comparison against `null` or `undefined` (`SEQ_NULL`, `SNEQ_NULL`,
`SEQ_UNDEF`, `SNEQ_UNDEF`, `EQ_NULLISH`, `NEQ_NULLISH`; the compiler
puts the literal second when the source has it first, `null === x`, and
`void 0` is `UNDEF` alone); a local and a constant or two locals loaded
together (`GETLOCAL_CONST`, `GETLOCAL2`, which `GETPROP_L`,
`GETINDEX_LL` and `LT_JF_LL` then fold further); a comparison and the
jump on it (`SEQ_JF`, `SNEQ_JF`, `SEQ_JT`, `SNEQ_JT`, `SEQ_NULL_JF`,
`SNEQ_NULL_JF`, and with the loads `SEQ_LC_JF` and `SEQ_LC_JT`, a
switch's case). On bsky.app's load the ops fell 17% for about 3% of
the running time: the dispatch is a small part of an op's cost, the
work in it the rest.

## Property caches

A property instruction (`GETPROP`, `GETPROP_L`, `GETPROP_THIS`,
`GETMETHOD`, `SETPROP`, `SETPROP_POP`) carries a u16 after its name,
empty when compiled, which the interpreter fills with the slot the name
was found in: on the object itself, or (bit 15 set) on its prototype, in
which case the own table has to lack the name. The next execution tries
that slot first: an ordinary object (no proxy, array, typed array or
other special shape), the slot in range, its key the name, its value not
an accessor, is the whole read, and for a write a writable own slot is
the whole write, with the collector's barrier when the object is old. A
miss takes the full lookup and fills the cache once; a site that misses
again sees more than one shape, or a name the cache cannot say, and
stays on the full lookup (`IC_MANY`). There are no hidden classes: the
guard is the key compare at the slot, which is sound because keys are
unique in a table, and the cost of a miss is the lookup plus one scan
to learn. The cache lives in the template's code, shared by every
closure of the function, and holds an index, never a pointer
(vm.mc, `prop_get_ic`, `set_prop_ic`). Measured on a read of the tenth
key of an object: 15.8 ns over the loop to 12.3; the scan it saves was
3 ns of the read, the rest is the dependent loads from the value to
the object to its table to the slot to the value's cell.

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

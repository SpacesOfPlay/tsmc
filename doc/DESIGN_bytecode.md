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

`OP_CALL` has a case of its own ahead of the general one it shares with
`OP_NEW` and `OP_SUPERCALL`: a compiled function with no rest parameter
or `arguments` object, not a class, generator or async body
(`FnTemplate.call_shape`, decided at its first call once the body is
compiled) is called with its frame built on the loop's own stack
pointer and base, a surplus argument dropped and a missing one filled
along with the slots, nothing rooted since nothing is allocated; a
native is called in place with the stack pointer written back first.
Everything else falls through to the general case. On the benches a
call 734 to 678 ms, a method call 706 to 611, fib 457 to 373.

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

The u16 was then taken further, from what a real page's misses were
made of (brmc's bsky.app: 29% of reads missed, on arrays' `length` and
methods, strings' and Maps' methods, natives' own properties, names
absent from an object and its chain, and sites seeing two layouts).
Its ranges now: below `IC_KPROTO` (0x4000) an own slot, which a
function or a native's own table may answer too; from `IC_KPROTO` a
slot in the prototype of the receiver's kind (`ic_kind_proto`: the
string, number, boolean, symbol or bigint prototype, a Map's, a
native's `Function.prototype`, a function's `fproto` when that is a
plain object or unset), the own table of a function or native checked
to lack the name; from `IC_AUX` (0x7000) an entry of the template's
`ic_aux` table; from `IC_PROTO` (0x8000) a slot in the object's own
prototype as before, an array allowed for a name that is not its
length or an element; and at the top `IC_ARRLEN` and `IC_STRLEN`, which
answer `length` from the array or string itself, with `IC_MANY` and
`IC_EMPTY`. An aux entry is either the two codes of a site that has
seen two layouts (a third makes it `IC_MANY`), or an absent name: the
prototype the receiver had when the name was found nowhere on it or
its chain, and the value of `g_proto_epoch` then. The epoch (object.mc)
moves when a name is added to or removed from the table of any object
that is some object's prototype (such objects carry `OBJF_IS_PROTO`
and their table `PROPS_IS_PROTO`, set when they first become one),
when an object first becomes a prototype, and when a prototype's own
prototype changes; so an absent entry is good while the receiver's own
table lacks the name, its prototype is the one the entry saw, and the
epoch stands. The entry holds the prototype's address for the compare
only and never follows it. The receiver's own slot stays inline in the
interpreter; the other ranges are a call (`ic_try`). On the micro-loops
over the loop's own cost: an array's length 10 to 2 ns, a string's 10
to 2.5, an absent name 15 to 7, an array method 22 to 14, a Map method
28 to 16, a native's own property 27 to 15.

## The code cache

A script's templates can be written out after a run and read back before
the next one (codecache.mc; `--code-cache <file>` on the CLI, and the
embedder's `vm_save_templates` and `vm_run_source_root`), so that a page
a browser returns to is not parsed and compiled again. The file is the
tree as it stood when written: a compiled template's code, constants,
positions, upvalue spec and the state of its property caches, a
still-lazy template's span and captured names; so a function compiled
lazily on one visit is compiled on the next. A constant that is a name
is written as the name and interned again on load, since atom numbers
are per run (the template keeps a bit per constant, `catom`, saying
which are names); a string is its bytes, a bigint its digits, any other
value its bits. The property caches are kept warm rather than cleared:
an own or prototype slot is guarded by the key at the slot, and an
absent entry is written without its prototype and epoch, so it misses
once and re-learns in place. The file names the source it was made from
by length and hash and the options that shape the code (lazy functions,
script globals), with the format's version and the size of the opcode
set folded in; a mismatch is a miss and the source is compiled. A lazy
template read back reparses from a copy of the source the loader makes
(`lazy_source_new`), the same as one the compiler made; the root holds
that source too, and the count of its lazy functions compiled since
tells an embedder whether the cache has grown. `--code-cache-verify`
runs every compile through a writing, a reading and a second writing,
compares the two writings and runs the reading; the golden tests run
under it. On brmc's saved bsky.app the second visit's first run went
511 to 180 ms, its lazy compiles 346 to 1 ms and its compiles 156 to 12,
the three loads 50 ms; the 9.5 MB bundle's cache is 10 MB.

The same form carries a compile from another thread. `vm_compile_ahead`
takes a source and no VM: it parses and compiles on a heap and an atom
table of its own and writes the templates out, and the VM reads the
bytes as it would a cache of the script. The heap never collects (its
thresholds are set past reach), so the compile needs no roots, and
everything it made goes with the heap. The one counter the compiler
shares across threads, the class sequence behind private names, is
bumped atomically; the lexer's byte tables are made before a second
thread lexes (`lexer_tables_init`). On the bundle the compile ahead
takes 149 ms where the VM's own compile takes 137 and the writing 9, and
the reading 18. `--code-cache-ahead` runs a script that way; the golden
tests run under it too.

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

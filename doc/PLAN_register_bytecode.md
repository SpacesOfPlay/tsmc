# Plan: register bytecode

Status: phase 0 done and phases 1 to 7 decided, 2026-11-08; phases 1 to 4 done, level 4 the default.

## Why

The interpreter is what is left of brmc's bsky.app load: the phase
accounting (`DESIGN_phases.md`) puts it at 1284 ms of a 2.1 s run, and
the sampler (`tools/ripsample.mc`, `tools/ripmap.py`) splits the loop's
own 732 ms a run as:

- about 160 ms getting from one op to the next: 16% of the loop's
  samples on the first two instructions of a case, where a dispatch
  lands, 6% on the dispatch sequences;
- GETLOCAL, POP, CONST, NULL and UNDEF are 40% of the ops executed,
  which move a value onto the stack for the next op to take off it;
- the rest the ops' own work, mostly first touches of cells the code
  reads anyway, which no change of bytecode removes.

The 21 fused instructions of 2026-11-05 took the op count from 161.7 to
133.6 million on the load (17%) for 3% of the running time, and the
most frequent pair left is 2.6% of the ops: fusing has taken what it
can. V8's interpreter runs about five register ops where this one runs
eight stack ops for the simplest loop (`brmc/doc/PLAN_M12_performance.md`).
A register bytecode removes the loads and the pops by construction: an
op names where its operands are and where its result goes.

What it can win, stated so that each phase can be held to it: the op
count down 30 to 40%, and with it most of the dispatch and the stack
traffic between ops; an estimate of 150 to 300 ms of bsky's 1284. What
it cannot win: the first touches of objects, the natives, the
collector, the compiles.

## The design

**Registers are frame slots.** A frame already has `n_slots` slots
from its base, the parameters and the locals, and the operand stack
grows above them in the same array. A register bytecode gives the
compiler more slots, the temporaries, and lets an op address any slot
by number: `ADD r3, r0, r1` reads two slots and writes a third. Nothing
about frames, calls, closures, the collector's marking of the stack or
a generator's saved state changes shape: a generator already saves
"slots + operand stack" (`JsGenerator.saved`), and the slots are what
is left.

**Three-address, not an accumulator.** V8's Ignition keeps one
implicit accumulator: most ops take one register operand and the
accumulator, which keeps the bytecode small. Here an accumulator would
be one more value live across every op of `vm_execute`, and the
loop's six callee-saved registers are already full (lang's
`doc/REPORT_codegen_vm_loop.md`, items 3 to 5: a seventh loop-wide
local spilled `stack` itself). Three-address ops keep all state in
the frame's slots, which are in L1; the stack pointer, which the loop
keeps in a register today, stops being touched by most ops, which
frees a register for the frame's base instead. The cost is operand
bytes: three u16 operands make an op seven bytes where a stack op is
one to three. Phase 0 measures what the larger code does to the
dispatch's fetch before anything is built on it.

**One loop, both kinds of op, converted a construct at a time.**
The stack ops stay. The compiler learns to put an expression's value
in a register, and construct by construct emits register ops where it
can and the stack ops where it has not yet been taught to. A register
op and a stack op meet through two bridging ops (`PUSHR r`, `POPR r`)
and through the slots both can see. Every step is a working engine, so
every step is measured and can be reverted on its own. The stack ops
that nothing emits any more are removed at the end.

**The compiler's interface.** `compile_expr(co, n)` today leaves the
value on the stack. It gains a sibling, `compile_expr_into(co, n,
want)`, which returns the register the value is in: the local's own
slot for a plain local read, a temporary otherwise, `want` when the
caller has a destination (the assignment's target). Temporaries are
allocated stack-wise per statement and freed at its end (Lua's
scheme), so the slot count is the maximum depth, which the compiler
already reaches in its operand stack today without counting it. A
construct not yet converted falls back: compile to the stack, `POPR`
into a temporary.

## What stays the same, and has to be checked to

- The template: code, constants, slots, the position table for stack
  traces, the inline cache slots in the instructions.
- Frames, calls, `this`, `arguments`, `new.target`, super calls.
- Closures and upvalues, cells and captured-by-value bindings.
- Generators and async functions: suspension saves the slots.
- Exceptions: a handler records an operand stack height today
  (`Handler.sp`); with values in registers the height at a try is the
  frame's slot count plus what the stack ops of the enclosing
  expression hold, which the fallback keeps right until the last
  phase.
- The code cache's format (a version bump each phase that adds ops),
  the lazy compile, the compile ahead on brmc's threads.
- The profiler, the phase accounting and the sampler's mapping (case
  names come from the source, so new cases show up by themselves).

## The checks every phase passes

Each phase ends with all of these, in this order, and a phase whose
numbers do not justify it is reverted, not kept:

1. **Behaviour.** ts-minc's `minc test` (396 checks, the goldens, the
   280 scripts under `--gc-stress`); `--code-cache-verify` over the
   goldens (every compile written, read back, run from the reading);
   `--code-cache-ahead` over them (every lazy function compiled
   ahead); `build/build.exe diff` against node; the test262 subset the
   runner keeps, no new failures. brmc's 35 test modules, and the
   saved bsky.app's shot the same set of checksums as head's.
2. **The op count.** A profiling build (`-DTSMC_PROF`) counts the ops
   executed on bsky's load and on each bench. Each phase states its
   expected drop before it is built and reports the measured one; the
   op mix from the same build shows which stack ops it replaced.
3. **The code.** Bytes of bytecode for bsky's bundle (the code cache's
   size is the measure), the compile time of the bundle (the phases'
   compile and lazy figures), `vm_execute`'s instruction count and its
   register seats from `minc asm` (a phase must not cost the loop a
   seat).
4. **The time.** The method: head built from the same tree after the
   last pull, five interleaved runs, the least of each; the 13-bench
   suite and bsky.app's busy, first run and first frame; the sampler
   on bsky for the dispatch share and the cases the phase touched.

A phase that lowers the op count as predicted and does not lower the
time is a finding about the premise, and stops the plan for a
decision rather than going on to the next.

## Phases

**0. Baseline and the prototype's verdict.** No compiler change.
Record the op count and mix of bsky's load and of each bench on head;
the bytecode size; the sampler's split. Then a throwaway prototype of
the premise on the micro-loops (`for (let i = 0; i < n; i++) s += i`,
a call in a loop, a property read in a loop): three to five register
ops hand-placed in the loop (`ADD_RRR`, `LT_JF_RR`, `INC_R`, a `MOV`)
and the loops compiled to them by a special case in the compiler,
measured against the stack form. Validates: that a register op is not
slower than the stack op it replaces once its operands are wider; what
seven-byte ops do to the dispatch's fetch; that the loop's seats hold.
Gate: the micro-loops at least 20% faster, else the design above is
wrong and the plan goes back to the drawing board with the numbers.

**1. Temporaries and the compiler's interface.** `compile_expr_into`
with only the fallback (stack, then `POPR` into the destination), the
temporary allocator, `n_slots` counting the temporaries, `PUSHR` and
`POPR`. Nothing is faster; everything still passes. Validates the
plumbing: a frame's slots grow by the temporaries and nothing else
changes; generators, try/catch and the code cache carry them; the
collector sees them. Check added: a debug build that clears a
statement's temporaries at its end, so that a stale value kept alive
in one shows up in the `--gc-stress` run. Expected op count: up, by
the bridging ops; this phase is judged on behaviour only.

**2. Locals and constants as operands.** A local read is its own
slot, a constant a `LOADK r, k`, `undefined`, `null`, `true` and
`false` their own loads; an assignment to a local writes the slot the
right-hand side is compiled into (`x = a + b` is one op). This is
where GETLOCAL, CONST, the literal pushes and PUTLOCAL go. Expected:
the largest single drop, a third of the op count's eventual fall.

**3. Arithmetic, comparisons and their jumps.** `ADD`, `SUB`, the
rest of the binary and unary operators on registers, with the int
fast paths the stack ops have; comparisons that jump (`JLT r, r,
target` and the others; `LT_JF_LL` is the stack VM's version of this
already, so its numbers are the yardstick); `++`/`--` on a local in
place. Expected: the loop-shaped code, the benches' share.

**4. Property access.** `GETPROP r, obj, key, ic`, `SETPROP obj, key,
val, ic`, `GETINDEX`, `SETINDEX`, `GETMETHOD` into two registers, with
the inline caches unchanged. Expected: GETPRL, GETPROP, GETMETHOD,
SETPRPOP, which are a third of the loop's samples on bsky, without
the pushes around them.

**5. Calls.** Arguments compiled into consecutive registers at the top
of the frame, so that the callee's frame starts at the first argument
and nothing is copied (`CALL r, fn, args, argc`); the result into a
register. The call fast path (`call_shape`, the 64-byte frame) stays.
Returns write the result into the caller's register. Expected: CALL
and RETURN's pushes and pops, and the `this`/undefined loads before a
call.

**6. Everything else.** Logical operators and the conditional,
template literals, object and array literals, destructuring, spread,
`for-in`/`for-of`, `switch`, closures, classes, generators and
`await`, `try`; each construct converted or left on the fallback by
what its op count on bsky says it is worth. The exception handler's
height becomes the slot count wherever no stack op is open at a try.

**7. Removal.** The stack ops nothing emits, and the fused stack ops
whose register forms replaced them, leave the loop; the code cache's
version bumps once more; `DESIGN_bytecode.md` is rewritten for the
register form; the plan records what each phase measured.

## Risks, and where each is caught

- **Bigger code, slower fetch.** Seven-byte ops may cost more in the
  dispatch's opcode fetch than the ops saved. Caught in phase 0 by the
  prototype, and by the bytecode size and the sampler's dispatch
  share in every phase after.
- **The loop's seats.** New loop-wide state spills `stack` or the
  frame base, as it did on 2026-11-07. Caught by `minc asm`'s seats
  in every phase's check 3.
- **Stale temporaries.** A temporary that still holds an object after
  its statement keeps it alive: a leak, not a wrong answer. Caught by
  the clearing debug build under `--gc-stress` (phase 1) and by the
  heap figures in the bsky trace.
- **Compile time.** The register allocator is more work per node; the
  lazy compiles and the compile ahead pay it. Caught by the phases'
  compile and lazy figures in check 3.
- **Exceptions and generators.** The handler's height and a
  generator's saved state are where a register bytecode most often
  goes wrong. Caught by the goldens for try/finally inside
  generators and async functions, test262's generator and try
  directories, and by phase 6 converting `try` last.
- **Two engines in one loop for weeks.** Every phase is a working
  engine, so the plan can stop after any of them with what it has;
  phase 7 is what makes it one engine again, and is not optional once
  phase 5 lands.
- **brmc.** Every phase is ported to brmc's `lib/js` with the same
  patch, and brmc's suite and the bsky shots are part of check 1.

## Cost

Phase 0 is days; phases 1 to 5 are a week or two each; 6 and 7 a week
or two together, depending on how much of 6 the numbers say is worth
converting. The compiler is 6300 lines and the loop's switch about 150
cases; phases 2 to 5 touch most of `compile_expr` and add about 40
register ops.

## Phase 0, measured (2026-11-08)

A throwaway prototype (kept outside the tree): four register ops,
`R_ADD` and `R_SUB` (slot = slot op slot), `R_BORK` (slot = slot | k)
and `R_GETPROP` (slot = slot.name, with the inline cache), emitted by
the compiler for `local = a + b`, `local = (a + b) | k`, `local = a | k`
and `local = o.name` when every operand is a plain local, behind
`tsmc --regproto`, so that one binary runs both forms.

**Validated six ways.**

1. *Op counts* (a profiling build, the flag off and on): `s = (s + i) |
   0` 8 ops an iteration to 5; `s = s + i` 6 to 4; `v = o.x; s = (s +
   v) | 0` 10 to 6; a loop with a call, which the prototype does not
   touch, 14 and 14. As predicted for each.
2. *Behaviour*: 445 test, bench and example scripts the same off and
   on (one live-network test differs run to run either way); the 261
   goldens the same under `--gc-stress`, 23 of them executing register
   ops; a probe of the slow paths (overflow, doubles, strings, BigInt,
   valueOf, a throwing valueOf, getters, a primitive receiver, a null
   receiver, a slot that is operand and destination) the same off, on
   and in node.
3. *The loop's register seats* (`minc asm`): unchanged.
4. *Time*, five interleaved rounds, the least and the greatest ns per
   iteration. Against head the gain looked like 2.5x on the first loop;
   that was a confound, the stack `BOR` having no int fast path where
   `R_BORK` had one. With the same fast path in the stack ops (the
   control):

   | loop | stack, fast path | register | gain | ops |
   |---|---|---|---|---|
   | `s = (s + i) \| 0` | 6.80–6.85 | 5.50–5.55 | 19% | 8 to 5 |
   | `s = s + i` | 6.15–6.25 | 4.90–5.45 | 20% | 6 to 4 |
   | `v = o.x; s = (s + v) \| 0` | 10.70–10.85 | 8.95–9.10 | 16% | 10 to 6 |
   | a call, untouched | 19.70–20.00 | 19.75–20.15 | 0 | 14 and 14 |

5. *The sampler*, independent of the wall clock: the property loop's
   samples 488 ms off and 391 on (20%); the ops removed (the two loads,
   the store, the add, the or) cost 123 ms and their register forms 90;
   the property read costs the same in either form.
6. *Against node --jitless*: the register forms are under node's
   interpreter on all three loops (5.5, 4.9, 9.0 ns against 11.6, 11.7,
   13.7); the call loop is 20 against 22.

**What it says.** The premise holds in direction and not in size: 37
to 40% fewer ops buy 16 to 20% on the loops, the gate's 20% at best.
A removed op saves 0.4 to 0.6 ns on a hot loop, its dispatch and its
stack store, where the op count alone would have said more.

**bsky.app.** The whole op mix of the load (a profiling build, 133.5
million ops): the moves a register bytecode removes are 37.7% (GETLOCAL
13.6, PUTLOCAL 7.8, CONST 4.9, POP 4.0, GETLOCAL2 2.2, GETLOCAL_CONST
1.2, SETLOCAL 1.0, NULL, UNDEF, THIS, DUP), less the moves a call's
arguments keep: 31 to 40% of the ops, 41 to 53 million. Two
projections of what that is worth: at the micro-loops' 0.4 to 0.6 ns a
removed op, 18 to 33 ms; at the 2.6 ns a removed op the pair fusions
measured on this page (28 million removed, 72 ms), 106 to 137 ms. The
second is the page's own figure and the likelier; it is 5 to 7% of
busy, under this plan's estimate of 150 to 300 ms.

**Found on the way.** The stack bitwise ops have no int fast path:
every `x | 0`, `x & m`, `x >> n` calls the coercion helper. With one,
the first loop goes 14.1 to 6.8 ns and the call loop 35 to 20. Bitwise
ops are 1.4% of bsky's ops, more of minified and asm-shaped code. This
is a change of its own, small, and worth taking whatever is decided
here.

**The decision.** Phases 1 to 7 are four to six weeks for a projected
100 to 140 ms of bsky's busy and the 16 to 20% the micro-loops show on
loop-shaped code. Going on is reasonable if loop-heavy pages and the
benches matter as much as bsky; stopping here is reasonable if bsky's
load is the measure, where the projected gain is about what the
memory-traffic and string work of this week gave together.

The decision, 2026-11-08: phases 1 to 7 go ahead; 20% on loop-shaped
code is worth it and the form is what later work builds on. The
bitwise fast path went in first (the bench suite 2960 to 2841 ms;
bsky.app busy about 50 ms better).

## Phase 1, done (2026-11-08)

`compile_expr_reg(co, n, want, later)` in compiler.mc: a plain local is
its own slot and costs nothing; anything else compiles to the stack and
is stored into `want` or a temporary from `alloc_slot`. `later` is what
the caller evaluates before it reads the slot: a local whose binding
that may store to (`reg_writes`: an assignment or update naming it,
destructuring included, nested functions not entered) is copied first,
so `x + (x = 5)` reads the old `x`. `reg_release` gives temporaries
back in stack order. `g_reg_level` says how far the form reaches, 0 by
default; `tsmc --reg=N` and brmc's `BRMC_REG=N` set it for measuring.
At level 1 a binary operator's operands go through the new path and are
pushed for the stack op, which exercises everything and speeds nothing.

Checks, all at level 1 against level 0 in the same binary
(`tools/reg_check.sh`, which every later phase reruns):

- 415 test, golden, bench and example scripts the same plainly, with
  every compile round-tripped through the code cache, and with every
  lazy function compiled ahead; the 261 goldens the same under
  `--gc-stress`, and under `--gc-stress --reg-clear`, which overwrites
  each temporary with undefined as it is released, so that code
  reading one afterwards would show.
- The alias cases (`x + (x = 5)`, `(y = 7) + y`, `z + z++`,
  destructuring into the operand, a member store between reads) the
  same as node at both levels. The engine has no mapped `arguments`
  (sloppy `arguments[0] = v` does not change the parameter), at level
  0 as well; noted, not this plan's.
- Exercised: the benches' op counts up 25 to 50% at level 1 (fib 157
  to 240 million), the fallback's stores and pushes, as planned.
- Unchanged by default: the code cache head and this build write is
  byte-identical for all 74 scripts that write one; both suites pass;
  bsky.app's shot the same at levels 0 and 1.

## Phase 2, done (2026-11-08)

Two ops, `MOV dst, src` and `LOADK dst, const`, and at level 2 an
assignment statement `x = e;` and a declaration `let x = e` to a plain
local compile `e` into the local's slot: a local source is a `MOV`, a
literal (number, string, boolean, null, `void` of a literal) a `LOADK`,
anything else the stack form and its store as before. Level 1 becomes
the exercise mode alone (`--reg=1`); the levels from 2 are the phases.
The code cache's version counts the new ops.

Checks at level 2, `tools/reg_check.sh`: 415 scripts plainly, through
the code cache's round trip and its compile ahead, and the 261 goldens
under `--gc-stress` with and without `--reg-clear`, no differences; a
probe of TDZ inside an initializer, shadowing, named function and
class expressions, a `var` initializer inside `with`, the same as node
at levels 0 and 2; both suites pass.

The op count moved less than this plan said it would. bsky.app's load
133.46 to 132.92 million (0.4%), the benches within a few thousand ops,
the shot the same. A statement that only moves a value is rare; the
loads and stores are other ops' operands and results. The load's pair
counts (600 pairs, 89% of the ops) say where they go:

- GETLOCAL (12.9% of the ops) feeds a call's arguments (2.2% with
  GETLOCAL2), the null comparisons that jump (1.8%), the nullish tests
  (0.6), returns (0.6), property reads and method lookups (1.1);
- PUTLOCAL (7.5%) stores a property read (2.6%, `x = o.p`), a local
  (0.7), a call's result (0.5), an addition (0.5), an index read (0.7);
- CONST (4.7%) feeds a property read or a local load beside it (2.3).

So the drop comes with the consumers: phase 3's comparisons and jumps
on slots, phase 4's property reads into slots, phase 5's arguments in
slots. Phase 2's `MOV` and `LOADK` are what those use to place their
operands; the phase is judged on behaviour, and its level stays off.

## Phase 3, done (2026-11-08)

Arithmetic and conditions on slots, level 3, now the default.

- `RADD`, `RSUB`, `RMUL`, `RDIV` (slot op slot) and their I forms (slot
  op an integer carried in the instruction); `RBIT` and `RBITI` for the
  bitwise and shift operators with a kind byte, and `RBORI` and `RBANDI`
  for `x | k` and `x & k`. Each writes its destination on the int and
  double fast paths and steps over the stack form of the same operation
  that follows it in the bytecode, nine bytes always (the two-operand
  load, the one-byte op, the store); anything else (strings, objects,
  BigInt, valueOf) runs that stack form, so the semantics are the stack
  VM's exactly. A string or other non-number literal operand keeps the
  expression on the stack, where `w + "px"` is no slower.
- `RJLT`, `RJGT`, `RJLE`, `RJGE` with their I forms, `RJSEQ` and `RJSNEQ`
  with a pool-constant K form, `RJNULLISH`, `RJNOTNULLISH`, `RJF`, `RJT`:
  the conditions of `if`, `while`, `for` and `?:` when the operands are
  plain locals or literals.
- `x = (a + b) | 0` computes the inner operation straight into `x`.

Three drafts, measured, before this one. A single `RARITH` and a single
`RJREL` with a kind byte spilled five values in the loop and lost to
the stack (the arith loop 6.75 to 10.55 ns). An op per operation with
constants from the pool was level (6.8 to 6.85). Then the sampler and a
side-by-side with phase 0's prototype found the last cost: the fast
path's `pc += size + skip` waited on loading the skip from the
bytecode, a dependent load on the dispatch's critical path. A fixed
nine-byte stack form makes the step a constant. The arith loop 6.65 to
5.10 ns, past the prototype's 5.6.

Checks: `tools/reg_check.sh` at level 3 (now parallel; the five modes
in about five minutes where they took over an hour), 417 scripts
plainly, through the code cache's round trip and its compile ahead,
and the 263 goldens under `--gc-stress` with and without `--reg-clear`,
no differences; a probe of every arithmetic and comparison operator
over nineteen operand kinds (-0, NaN, Infinity, strings, null,
undefined, booleans, BigInt, valueOf, a throwing valueOf), 35 KB of
results, the same at level 0, level 3 and in node; both suites pass
with level 3 the default (one brmc run of seven had a failure whose
output was not kept; six did not repeat it, and it is noted as open).

Ops: bsky.app's load 131.97 to 126.51 million (4.1%); the benches 0.4
to 17% fewer (strindex 17, bytes 13.6, iterators 13.5, fib 11.8).

Time, levels 0 and 3 in one binary, five interleaved runs:

| | level 0 | level 3 |
|---|---|---|
| `s = (s + i) \| 0` | 6.65 ns | 5.10 |
| `s = s + i` | 6.20 | 5.05 |
| `v = o.x; s = (s + v) \| 0` | 10.80 | 8.80 |
| a loop with a call | 19.40 | 19.50 |
| the bench suite | 2827 ms | 2779 (fib 347 to 332, bytes 198 to 191; none slower) |
| bsky.app busy | 1767 to 1789 | 1753 to 1785 |

A first reading of the bench suite said level 3 was 5% slower: its
level-3 side ran through a shell wrapper, which costs about 11 ms a run
under MSYS, 140 ms over the suite. The same wrapper sits in the phase
accounting's cost in `DESIGN_phases.md`, corrected there.

## Phase 4, done (2026-11-08)

Property and index access on slots, level 4, now the default.

- `RGETPROP dst, obj, name, ic` and `RSETPROP obj, name, val, ic`: the
  inline cache as before (`prop_get_ic_fast`, then `prop_get_ic`;
  `set_prop_ic`), the operands read from and the result written to
  slots. `RGETINDEX dst, obj, key`: an array's own element inline, else
  `op_getindex` on the pushed pair. `RSETINDEX obj, key, val`: an
  array's element inline when the array is not frozen and the index is
  in range or the array extensible, else the ten-byte stack form that
  follows it.
- The compiler takes a plain `.name` or `[key]` whose object is a plain
  local or such a read itself (`a.b.c`), and whose key is a plain local
  or a literal: as an operand, as `x = o.p`, and as the statements
  `o.p = v;` and `o[k] = v;`, object, key and value evaluated in that
  order. `this.p`, optional chains, private names, `super` and `{}.x`
  keep their stack forms, which have fused ops of their own.

Checks: `tools/reg_check.sh` at level 4, 417 scripts and the 263
goldens in all five modes, no differences; a probe of reads and writes
through getters and setters, prototypes, holes, an element on
Array.prototype, typed arrays in and out of range, string, symbol and
object keys with a toString, null and undefined receivers, primitives,
frozen, non-extensible and read-only targets in strict and sloppy code,
and a value expression that rebinds the object or the key, the same at
levels 0 and 4. It differs from node in one place at both levels: a
setter defined on an array index is not called, which is the engine's
and not this plan's. Both suites pass with level 4 the default, brmc's
twice.

Ops: bsky.app's load 126.44 to 123.65 million against level 3 (2.2%);
proto_chain 16.2% fewer, objlit 4.9, bytes 4.1.

Time, levels 3 and 4 in one binary, five interleaved runs: the bench
suite 2761 to 2742 ms (objlit 176 to 171, proto_chain 204 to 199,
nothing slower beyond 2 ms); the property micro-loop 8.75 to 8.55 ns;
bsky.app busy 1740 to 1750 against 1736 to 1761, flat, the shot the
same.

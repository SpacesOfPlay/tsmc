# The interpreter loop's machine code: what minc emits, and what would help

For the lang project. `vm_execute` in `src/vm.mc` is the bytecode
interpreter: one function, a `while true` around a `switch` of about 150
cases, the loop's state in locals (`vm`, `stack`, `sp`, `pc`, `fr`, `t`,
`code`). It runs about 160 million ops for a bsky.app load, and the
cost of an op is its memory traffic, not its instruction count: the
fused instructions took 17% of the ops for 3% of the time, and two
experiments that cut instructions (the frame's base and the stack
pointer kept as pointers) changed nothing because the allocator spilled
the new locals. The dump below is from brmc's build of the same source
on minc 0.9.19:

```
minc asm src/brmc.mc vm_execute > vm.asm      # brmc; or in ts-minc:
minc asm src/main.mc vm_execute > vm.asm
```

The allocator holds `vm` in rbp, `stack` in r13, `sp` in r12 (an i32),
`pc` in r14 and `fr` in r15, with rbx for one more; the handlers use the
scratch registers. Four patterns account for most of what an op does
beyond its own loads and stores.

## 1. The dispatch: five instructions and two dependent loads

The dispatch is already threaded: minc copies the switch's jump into the
tail of every case that ends in `continue`, so there is no shared
dispatch block. What it copies is

```
  movzx r10, byte ptr [r14]              ; op = *pc
  inc r14
  mov rcx, r10
  lea rax, [rip - 0x948]                 ; the jump table
  movsxd rcx, dword ptr [rax + rcx*4]    ; a 32-bit offset
  add rax, rcx
  jmp rax
```

The table holds 32-bit offsets from its own address, so reaching a
handler is a load, a sign-extension, an add and an indirect jump, with
the `lea` recomputed in every copy. Two forms would be shorter: 8-byte
absolute entries, `jmp qword ptr [rax + rcx*8]`, which needs base
relocations in the PE and ELF writers; or the table's address kept in a
register across the loop, which is pattern 4.

## 2. An i32 index into a pointer

`*(stack + sp)` with `sp` an `i32` becomes

```
  movsxd r11, r12d
  shl r11, 3
  add r11, r13
  mov rdx, qword ptr [r11]
```

and `*(stack + sp - 1)` adds a `lea r9, [r11 - 8]`. The x64 addressing
mode does the scale and the add: `movsxd r11, r12d` then
`mov rdx, qword ptr [r13 + r11*8]`, or with a displacement for the
`- 1`. Every stack access in the loop pays this, two to three
instructions each, and GETLOCAL does it twice (the frame's slot and the
push). The engine tried `sp` as a `Value*` so that the access is the
register itself: the compiler then copied through two temporaries at
the store and saved one instruction net.

## 3. The loop's invariants reloaded

GETLOCAL, the most frequent op, is

```
  movsxd r11, dword ptr [r15 + 0x18]     ; fr.base, every time
  shl r11, 3
  add r11, r13
  movzx rsi, word ptr [r14]              ; the operand
  shl rsi, 3
  add r11, rsi
  movsxd rsi, r12d
  shl rsi, 3
  add rsi, r13
  mov rdx, qword ptr [r11]
  mov qword ptr [rsi], rdx
  inc r12
  add r14, 2
```

`fr.base` does not change between calls and returns, and `t.consts`
(CONST, 5% of the ops) and `t.code` likewise, yet each access loads it
from the frame record. The engine kept `stack + fr.base` in a local
beside `fr`, set where `fr` is set: the allocator spilled it, so the
load moved from the frame record to the stack frame and nothing was
gained. What would help is the allocator preferring, in a function with
one hot loop, the values the loop reads over the values its cold paths
read; the loop's six invariants are known, and the handlers' own
temporaries are short-lived and could use the scratch registers they
already use.

## 4. What the callee-saved registers hold

With rbx, rbp and r12 to r15 taken by the loop's state, there is no
register left for a seventh invariant, and the table's address (1) and
the frame's base (3) are recomputed or reloaded per op. The function has
about 14,700 instructions; the allocator's choice of what to keep is
global to it. A per-loop decision, or a hint on a local (`@register`,
or an attribute on the loop), would let the engine say which six matter.

## Small things seen

- `mov rax, rbp` followed by `add dword ptr [rax + 0x4700], 1`: the
  copy is not needed, the address mode takes rbp.
- `--unchecked` changes nothing here (3146 to 3137 ms over the bench
  suite): the loop indexes through pointers already.
- `break` inside a `switch` case leaves the enclosing loop, not the
  switch. Withdrawn: `break case;` is the statement for that, in
  LANGUAGE.md's control-flow section and already in this file 21
  times. The engine's author missed it, not the language.

## What the engine did meanwhile, for scale

On the engine's side, three memory-traffic changes measured on bsky.app
(three interleaved runs of one binary against the other) and the bench
suite (thirteen benches, the minimum of three each):

- An object's first properties in its own cell (`js_new_object_room`:
  the literal's count, at least four; six for a constructor's
  instance): no pool block per object, and the entries on the object's
  lines. Marking 120 to 104 ms.
- A closure's upvalues in its cell likewise.
- The pending-exception check off the pure ops: once before the loop,
  then only after an op that called out. One load and one branch fewer
  per op; the bench suite 3149 to 3097 ms.

Together: bsky.app busy 1959 to 1964 ms against 1880 to 1895, the first
frame 2169 to 2182 against 2090 to 2110, the peak working set 795 to
777 MB; the bench suite 3145 to 3103. The patterns above are what is
left per op, and they are the compiler's.

## After the compiler's answer (minc at lang 0fa308b5, 2026-11-07)

Three lang commits took the report up: small struct copies lower to a
load and a store so the address fusion sees them (b7b65e1b), the jump
table is 8-byte absolute entries in `.rdata` and the dispatch is
`lea rax, [rip + table]; jmp qword ptr [rax + r11*8]` (d0626513,
0fa308b5), and the `mov rax, rbp` copy is gone. Verified on the same
engine source rebuilt with the new compiler:

- `vm_execute` 14698 to 14142 instructions. The dispatch copy is four
  instructions where it was seven; GETLOCAL is eight before its
  dispatch where it was thirteen, the frame slot read as
  `mov rdi, [rdi + rsi*8]` and the push as `mov [r13 + r9*8], rdi`;
  the 102 `mov rax, rbp` are zero.
- Both suites pass: ts-minc's 396 checks, brmc's 35 modules.
- The bench suite 3105 to 3057 ms (fib 380 to 365, classes 366 to 356,
  nothing slower beyond noise). bsky.app, three interleaved runs, is
  within noise: busy 1808 to 1841 ms against 1795 to 1846, the shots
  the same. Which is the report's own premise measured: the op's cost
  is its memory traffic, and these fixes removed instructions.

What the new code still shows, in order of the traffic it costs:

### 5. The invariants are spilled, not merely reloaded

Pattern 3 stands and is the one that still touches memory. `t` lives
at `[rsp + 0x78]` (80 uses) and `t.code` at `[rsp + 0x80]` (34 uses):
every taken jump is `add r14, qword ptr [rsp + 0x80]`, and CONST is
three dependent loads for a constant,

```
  mov r8, qword ptr [rsp + 0x78]         ; t, from the stack frame
  mov r8, qword ptr [r8 + 0x38]          ; t.consts
  mov r8, qword ptr [r8 + r9*8]          ; the constant
```

while `fr.base` is still `movsxd rdi, dword ptr [r15 + 0x18]` per
local access (40 sites). The six callee-saved registers hold `vm`,
`stack`, `sp`, `pc`, `fr` and the int-tag mask; the frame base, the
code base and the constants would be three more. A register hint, or
an allocator that weighs the loop's reads over the cold paths', is the
ask as before.

### 6. A store with a displacement does not fuse

The load side fuses with a displacement (`mov rsi, [r13 + rdi*8 - 8]`
in SETLOCAL and ADD); the store side does not. ADD's result store,
`*(stack + sp - 1) = v` after `sp--`, is

```
  lea r8, [r12 - 1]
  mov r12, r8
  movsxd r8, r8d
  shl r8, 3
  add r8, r13
  mov qword ptr [r8 - 8], r9
```

where `movsxd r8, r8d; mov [r13 + r8*8 - 8], r9` would do. Twelve
such stores in the function; 137 `movsxd; shl 3; add` triples remain
in all, 91 of them feeding a plain `mov r, [r]` load.

### 7. A second load of the same address is recomputed

JUMPF reads `*(stack + sp)` twice with no store between (is it a
boolean; is it false). The first is fused, the second rebuilds the
address and reloads a value that is still in r8:

```
  movsxd r8, r9d
  mov r8, qword ptr [r13 + r8*8]
  ...two compares on r8...
  movsxd r9, r9d
  shl r9, 3
  add r9, r13
  mov r9, qword ptr [r9]
```

One load and three instructions per occurrence.

### 8. A value for the cold path is spilled on the hot path

ADD computes the i64 sum, stores it to `[rsp + 0x88]`, tests the i32
range, and on the common in-range path never reads it back; only the
overflow path reloads it for `vcvtsi2sd`. The store belongs on that
path. GETPROP's inline-cache hit path begins with six stores to the
stack frame (`[rsp + 0x88]` to `[rsp + 0xb8]`) of values the hit never
needs again. The function's frame is 0x758 bytes and `[rsp + ...]`
appears 2912 times.

### 9. A boolean goes through memory

A `bool` assigned in more than one branch is kept in a stack byte and
tested from there. LT_JF's comparison result:

```
  cmp esi, edi
  setl dil
  movzx edi, dil
  mov byte ptr [rsp + 0x230], dil
  jmp .L319
  ...
.L319:
  movzx rsi, byte ptr [rsp + 0x230]
  test rsi, rsi
  jne .L3
```

A `cmp; jl` per branch would replace nine instructions and a store and
a load. Nine such sites in the function; JUMP's `bool back` is the
same shape without the store (`setb sil; movzx esi, sil; test rsi,
rsi; je`).

### Small things seen this time

- `lea r9, [r12 - 1]; mov r12, r9` for `sp--` when the new value is
  used as an index (eight sites); `dec r12` and index by r12.
- LT_JF's `movsxd rsi, esi; mov r9, rsi; movsxd rdi, edi; mov r8, rdi`:
  each operand in two registers, a copy each.
- A 10-byte `movabs` for a tag constant repeated within a handler
  (JUMPF loads the false value twice); the int tag is hoisted into r10
  and the mask into rbx, so the allocator can hoist them, and these
  would go the same way if a register were free (item 5).

### On the engine's side, from the same reading

Not the compiler's, noted for the engine's next batch:

- GETUPVAL walks `fr.fun` then `fun.upvals`, two dependent loads per
  upvalue read; the upvals pointer could sit in the frame record.
- The four relational jump ops share a case and pick the comparison by
  testing the op byte up to three times; four cases, which the
  dispatch already distinguishes, would be straight-line.
- The pending-check restructuring of the hole-check and return ops
  nested if/else where `break case;` says the same thing; a cleanup,
  to be timed like any loop change.

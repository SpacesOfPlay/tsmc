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
  switch (checked with a small program). The engine wanted a way out of
  a case to the code after the switch and restructured instead; a note
  in LANGUAGE.md would save the next reader the experiment.

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

// bytecode.mc — opcode set, function templates, chunk writer.
//
// One-byte opcodes, little-endian u16 operands, absolute jumps.
// Templates are plain allocations owned by the VM; their constants
// are marked as GC roots by the VM's mark hook.

import vec;
import value;

enum Op {
    OP_CONST,        // u16 const idx
    OP_UNDEF, OP_NULL, OP_TRUE, OP_FALSE,
    OP_HOLE,         // pushes an array-hole sentinel (elisions)
    OP_POP, OP_DUP, OP_DUP2,
    OP_THIS,

    OP_GETLOCAL,     // u16 slot
    OP_SETLOCAL,     // u16 slot; keeps value on stack
    OP_GETLOCAL_CHK, // TDZ-checked read
    OP_SETHOLE,      // u16 slot := hole
    OP_NEWCELL_UNDEF,// u16 slot := box(undefined)
    OP_NEWCELL_HOLE, // u16 slot := box(hole)
    OP_CELLIFY,      // u16 slot := box(slot)
    OP_GETCELL, OP_SETCELL, OP_GETCELL_CHK,      // u16 slot holding a box
    OP_GETUPVAL, OP_SETUPVAL, OP_GETUPVAL_CHK,   // u16 upvalue index
    OP_GETGLOBAL,    // u16 const idx (name string); throws when missing
    OP_GETGLOBAL_SOFT,   // pushes undefined when missing (typeof)
    OP_SETGLOBAL,    // u16 const idx; keeps value

    OP_ADD, OP_SUB, OP_MUL, OP_DIV, OP_MOD, OP_POW,
    OP_NEG, OP_TONUM,
    OP_INC, OP_DEC,   // ++/-- step, type-appropriate (Number or BigInt)
    OP_NOT, OP_BITNOT, OP_TYPEOF,
    OP_EQ, OP_NEQ, OP_SEQ, OP_SNEQ,
    OP_LT, OP_GT, OP_LE, OP_GE,
    OP_BAND, OP_BOR, OP_BXOR, OP_SHL, OP_SHR, OP_USHR,
    OP_INSTANCEOF, OP_IN,

    OP_JUMP,         // u16 target
    OP_JUMPF,        // pop; jump when falsy
    OP_JUMPT,        // pop; jump when truthy
    OP_JF_KEEP,      // falsy: jump, keep; else pop      (&&)
    OP_JT_KEEP,      // truthy: jump, keep; else pop     (||)
    OP_JNN_KEEP,     // not nullish: jump, keep; else pop (??)

    OP_CLOSURE,      // u16 sub-template idx
    OP_CALL,         // u16 argc; stack: fn this args...
    OP_NEW,          // u16 argc; stack: ctor args...
    OP_RETURN,

    OP_NEWOBJ,
    OP_NEWARR,       // u16 element count popped
    OP_GETPROP,      // u16 const idx (name)
    OP_SETPROP,      // u16 const idx; pops obj, keeps value
    OP_DEFMETHOD,    // u16 const idx; like SETPROP but non-enumerable
    OP_GETINDEX, OP_SETINDEX,
    OP_GETMETHOD,    // u16 const idx; pops obj, pushes fn then obj
    OP_GETMETHOD_DYN,// pops key, obj; pushes fn then obj
    OP_DELPROP,      // u16 const idx
    OP_DELINDEX,

    OP_TRY_PUSH,     // u16 catch target
    OP_TRY_POP,
    OP_THROW,

    OP_SETPROTO,     // [obj, proto] pops proto, keeps obj
    OP_DEFGETTER,    // u16 name; [obj, fn] pops fn, keeps obj
    OP_DEFSETTER,    // u16 name; [obj, fn] pops fn, keeps obj
    OP_ARR_APPEND,   // [arr, v] pops v, keeps arr
    OP_ARR_SPREAD,   // [arr, src] pops src; appends elements/chars
    OP_OBJ_SPREAD,   // [obj, src] pops src; copies own props
    OP_OBJ_REST,     // u16 const idx of excluded-keys array; [src] -> rest obj
    OP_ARR_SLICE_FROM, // u16 start; [arr/str] -> new array of the tail
    OP_CALL_ARRAY,   // [fn, this, argsarr] -> result
    OP_NEW_ARRAY,    // [ctor, argsarr] -> instance
    OP_JUMP_NULLISH, // u16; top nullish: pop, jump
    OP_JUMP_NULLISH_METH, // u16; peek(1) nullish: pop 2, jump
    OP_CHECK_ITERABLE,   // top must be an array or string
    OP_KEYS,         // [v] -> array of own enumerable key strings

    OP_YIELD,        // suspend the generator frame; top is the value
    OP_GET_ITER,     // [v] -> iterator via Symbol.iterator
    OP_ITER_NEXT,    // [iter] -> [value, done]
    OP_REGEX         // u16 source const, u16 flags const -> RegExp object
}

struct TmplUpval {
    bool from_parent_slot;   // else from parent's upvalues
    i32 index;
}

struct FnTemplate {
    str name;            // owned copy
    i32 n_params;
    i32 n_slots;
    bool has_rest;       // last param collects surplus arguments
    bool is_gen;         // calls build a generator object
    bool is_async;       // calls build generator state + promise
    u8* code;
    i32 code_len;
    Value* consts;       // GC-rooted via the VM mark hook
    i32 n_consts;
    TmplUpval* upvals;
    i32 n_upvals;
    FnTemplate** subs;
    i32 n_subs;
}

type TmplPtr = FnTemplate*;

struct Chunk {
    Vec<u8> code;
    Vec<Value> consts;
    Vec<TmplUpval> upvals;
    Vec<TmplPtr> subs;
}

void chunk_init(Chunk* ch) {
    vec_init<u8>(&ch.code, 64);
    vec_init<Value>(&ch.consts, 8);
    vec_init<TmplUpval>(&ch.upvals, 4);
    vec_init<TmplPtr>(&ch.subs, 4);
}

void ch_op(Chunk* ch, i32 op) {
    vec_push(&ch.code, cast(u8, op));
}

void ch_u16(Chunk* ch, i32 v) {
    vec_push(&ch.code, cast(u8, v));
    vec_push(&ch.code, cast(u8, v >> 8));
}

void ch_op_u16(Chunk* ch, i32 op, i32 v) {
    ch_op(ch, op);
    ch_u16(ch, v);
}

i32 ch_add_const(Chunk* ch, Value v) {
    vec_push(&ch.consts, v);
    return ch.consts.len - 1;
}

// Emits a jump with a placeholder target; returns the patch position.
i32 ch_jump(Chunk* ch, i32 op) {
    ch_op(ch, op);
    i32 at = ch.code.len;
    ch_u16(ch, 0xFFFF);
    return at;
}

void ch_patch(Chunk* ch, i32 at) {
    i32 target = ch.code.len;
    vec_set(&ch.code, at, cast(u8, target));
    vec_set(&ch.code, at + 1, cast(u8, target >> 8));
}

void ch_patch_to(Chunk* ch, i32 at, i32 target) {
    vec_set(&ch.code, at, cast(u8, target));
    vec_set(&ch.code, at + 1, cast(u8, target >> 8));
}

i32 ch_pos(Chunk* ch) {
    return ch.code.len;
}

// Moves the chunk's contents into a heap-owned template.
// Replaces a template's name with an owned copy (used to give a class
// constructor the class's name rather than "constructor").
void tmpl_set_name(FnTemplate* t, str name) {
    if t.name.len > 0 { free(t.name.data); }
    t.name.data = null;
    t.name.len = 0;
    if name.len > 0 {
        u8* nb = alloc<u8>(name.len);
        memcpy(nb, name.data, name.len);
        t.name.data = nb;
        t.name.len = name.len;
    }
}

FnTemplate* chunk_finish(Chunk* ch, str name, i32 n_params, i32 n_slots, bool has_rest,
        bool is_gen, bool is_async) {
    FnTemplate* t = new(FnTemplate);
    t.has_rest = has_rest;
    t.is_gen = is_gen;
    t.is_async = is_async;
    if name.len > 0 {
        u8* nb = alloc<u8>(name.len);
        memcpy(nb, name.data, name.len);
        t.name.data = nb;
        t.name.len = name.len;
    }
    t.n_params = n_params;
    t.n_slots = n_slots;
    t.code_len = ch.code.len;
    t.code = alloc<u8>(ch.code.len + 1);
    memcpy(t.code, ch.code.data, ch.code.len);
    t.n_consts = ch.consts.len;
    if t.n_consts > 0 {
        t.consts = alloc<Value>(t.n_consts);
        for i32 i = 0; i < t.n_consts; i++ {
            *(t.consts + i) = vec_get(&ch.consts, i);
        }
    }
    t.n_upvals = ch.upvals.len;
    if t.n_upvals > 0 {
        t.upvals = alloc<TmplUpval>(t.n_upvals);
        for i32 i = 0; i < t.n_upvals; i++ {
            *(t.upvals + i) = vec_get(&ch.upvals, i);
        }
    }
    t.n_subs = ch.subs.len;
    if t.n_subs > 0 {
        t.subs = cast(FnTemplate**, alloc(cast(i64, t.n_subs) * 8));
        for i32 i = 0; i < t.n_subs; i++ {
            *(t.subs + i) = vec_get(&ch.subs, i);
        }
    }
    vec_free(&ch.code);
    vec_free(&ch.consts);
    vec_free(&ch.upvals);
    vec_free(&ch.subs);
    return t;
}

void template_free(FnTemplate* t) {
    for i32 i = 0; i < t.n_subs; i++ {
        template_free(*(t.subs + i));
    }
    if t.name.data != null { free(t.name.data); }
    free(t.code);
    if t.consts != null { free(t.consts); }
    if t.upvals != null { free(t.upvals); }
    if t.subs != null { free(t.subs); }
    free(t);
}

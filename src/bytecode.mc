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
    OP_ARGUMENTS,    // pushes this frame's arguments object
    OP_CURFUNC,      // pushes the currently-executing function (named fn expr)
    OP_NEWTARGET,    // pushes new.target: the constructor, or undefined
    OP_SUPERCALL,    // like OP_CALL but propagates the caller's new.target
    OP_DYNIMPORT,    // pops (referrer, spec); pushes a promise of the namespace

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
    OP_TOSTR,         // ToString (string hint) — template substitutions
    OP_INC, OP_DEC,   // ++/-- step, type-appropriate (Number or BigInt)
    OP_NOT, OP_BITNOT, OP_TYPEOF,
    OP_EQ, OP_NEQ, OP_SEQ, OP_SNEQ,
    OP_LT, OP_GT, OP_LE, OP_GE,
    OP_BAND, OP_BOR, OP_BXOR, OP_SHL, OP_SHR, OP_USHR,
    OP_INSTANCEOF, OP_IN,
    OP_HASPRIVATE,   // u16 const idx (private atom); pops obj, pushes #name in obj

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
    OP_CATCH_ENTER,  // at a catch target: re-throw a return completion instead
                     // of binding it, so only `finally` sees it
    OP_THROW,

    OP_SETPROTO,     // [obj, proto] pops proto, keeps obj
    // Object literals define their own properties rather than assigning them,
    // so an inherited setter (notably __proto__) is not invoked.
    OP_DEFPROP,      // u16 name; [obj, val] pops val, keeps obj
    OP_DEFPROP_DYN,  // [obj, key, val] pops key+val, keeps obj
    // Accessor definition. The trailing u16 is 1 when the property is
    // enumerable (object literals) and 0 when it is not (class bodies).
    OP_DEFGETTER,    // u16 name, u16 enum; [obj, fn] pops fn, keeps obj
    OP_DEFSETTER,    // u16 name, u16 enum; [obj, fn] pops fn, keeps obj
    OP_DEFGETTER_DYN,// u16 enum; [obj, key, fn] pops key+fn, keeps obj
    OP_DEFSETTER_DYN,// u16 enum; [obj, key, fn] pops key+fn, keeps obj
    OP_ARR_APPEND,   // [arr, v] pops v, keeps arr
    OP_ARR_SPREAD,   // [arr, src] pops src; appends elements/chars
    OP_OBJ_SPREAD,   // [obj, src] pops src; copies own props
    OP_OBJ_REST,     // u16 const idx of excluded-keys array; [src] -> rest obj
    OP_ARR_SLICE_FROM, // u16 start; [arr/str] -> new array of the tail
    OP_CALL_ARRAY,   // [fn, this, argsarr] -> result
    OP_NEW_ARRAY,    // [ctor, argsarr] -> instance
    OP_SUPERCALL_ARRAY, // [fn, this, argsarr] -> result, propagating new.target
    OP_JUMP_NULLISH, // u16; top nullish: pop, jump
    OP_JUMP_NULLISH_METH, // u16; peek(1) nullish: pop 2, jump
    OP_CHECK_ITERABLE,   // top must be an array or string
    OP_KEYS,         // [v] -> array of own enumerable key strings

    OP_YIELD,        // suspend the generator frame; top is the value
    OP_GET_ITER,     // [v] -> iterator via Symbol.iterator
    OP_GET_AITER,    // [v] -> iterator via Symbol.asyncIterator, else Symbol.iterator
    OP_ITER_SEND,    // [iter, sent] -> [value, done] via iter.next(sent)
    OP_ITER_NEXT,    // [iter] -> [value, done]
    // Array destructuring drives the iterator through these. The u16 operand
    // is the local slot holding the "exhausted" flag, so a spent iterator is
    // never stepped again.
    OP_ITER_STEP,    // u16 done slot; [iter] -> value (undefined once done)
    OP_ITER_REST,    // u16 done slot; [iter] -> array of the remaining values
    OP_ITER_CLOSE,   // u16 done slot; [iter] -> ; calls return() unless done
    OP_REGEX         // u16 source const, u16 flags const -> RegExp object
}

struct TmplUpval {
    bool from_parent_slot;   // else from parent's upvalues
    i32 index;
}

struct FnTemplate {
    str name;            // owned copy
    i32 n_params;
    i32 arity;           // Function.length: params before the first
                         // default value or rest parameter
    i32 n_slots;
    bool has_rest;       // last param collects surplus arguments
    bool is_gen;         // calls build a generator object
    bool is_async;       // calls build generator state + promise
    bool needs_arguments; // references `arguments`; build it at call time
    u8* code;
    i32 code_len;
    Value* consts;       // GC-rooted via the VM mark hook
    i32 n_consts;
    TmplUpval* upvals;
    i32 n_upvals;
    FnTemplate** subs;
    i32 n_subs;
    PosEntry* pos;       // code_off -> source line/col, for stack traces
    i32 n_pos;
    str src_name;        // source filename (borrowed; owned by the module)
}

type TmplPtr = FnTemplate*;

// Maps a bytecode offset to a 1-based source line/column, for stack
// traces. Entries are recorded in increasing code_off order.
struct PosEntry {
    i32 code_off;
    i32 line;
    i32 col;
}

struct Chunk {
    Vec<u8> code;
    Vec<Value> consts;
    Vec<TmplUpval> upvals;
    Vec<TmplPtr> subs;
    Vec<PosEntry> pos;
}

void chunk_init(Chunk* ch) {
    vec_init<u8>(&ch.code, 64);
    vec_init<Value>(&ch.consts, 8);
    vec_init<TmplUpval>(&ch.upvals, 4);
    vec_init<TmplPtr>(&ch.subs, 4);
    vec_init<PosEntry>(&ch.pos, 16);
}

// Records the source position active at the current code offset. When the
// offset already has an entry, the later position wins.
void ch_record_pos(Chunk* ch, i32 line, i32 col) {
    i32 off = ch.code.len;
    if ch.pos.len > 0 && vec_get(&ch.pos, ch.pos.len - 1).code_off == off {
        PosEntry* last = ch.pos.data + (ch.pos.len - 1);
        last.line = line;
        last.col = col;
        return;
    }
    PosEntry e;
    e.code_off = off;
    e.line = line;
    e.col = col;
    vec_push(&ch.pos, e);
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
    // default: every parameter is required (compile_callable overrides
    // this with the default/rest-aware count).
    if has_rest && n_params > 0 { t.arity = n_params - 1; }
    else { t.arity = n_params; }
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
    t.n_pos = ch.pos.len;
    if t.n_pos > 0 {
        t.pos = alloc<PosEntry>(t.n_pos);
        for i32 i = 0; i < t.n_pos; i++ {
            *(t.pos + i) = vec_get(&ch.pos, i);
        }
    }
    vec_free(&ch.code);
    vec_free(&ch.consts);
    vec_free(&ch.upvals);
    vec_free(&ch.subs);
    vec_free(&ch.pos);
    return t;
}

// The 1-based line/col for a bytecode offset (the last entry at or before
// it); 0/0 if the template carries no position table.
void tmpl_pos(FnTemplate* t, i32 code_off, i32* line, i32* col) {
    *line = 0;
    *col = 0;
    i32 lo = 0;
    i32 hi = t.n_pos - 1;
    i32 best = -1;
    while lo <= hi {
        i32 mid = (lo + hi) / 2;
        if (t.pos + mid).code_off <= code_off {
            best = mid;
            lo = mid + 1;
        } else {
            hi = mid - 1;
        }
    }
    if best >= 0 {
        *line = (t.pos + best).line;
        *col = (t.pos + best).col;
    }
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
    if t.pos != null { free(t.pos); }
    free(t);
}

// bytecode.mc — opcode set, function templates, chunk writer.
//
// One-byte opcodes, little-endian u16 operands, absolute jumps.
// Templates are plain allocations owned by the VM; their constants
// are marked as GC roots by the VM's mark hook.

import vec;
import value;
import diag;

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
    // u16 slot: the local stepped by one, ToNumeric first. What `i++` in
    // statement position on a plain local compiles to, in place of a load, a
    // ToNumeric, an increment and a store.
    OP_INCLOCAL,
    OP_DECLOCAL,
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
    OP_SETEXPORT,    // u16 name; [ns, val] -> [val]: the namespace's own copy
                     // of an exported binding, which only the module writes
    OP_DELGLOBAL,    // u16 const idx; removes a global binding -> bool
    OP_WITH_OBJ,     // [v] -> [ToObject(v)]; TypeError on null or undefined
    OP_WITH_HAS,     // u16 const idx (name); [obj] -> [bool]: does the object
                     // a `with` introduced answer for this name
    OP_WITH_GET,     // u16 name; [obj] -> [value]. The object is asked for the
                     // property again: a getter or a proxy trap may have
                     // removed it since it answered for the name, and then the
                     // reference is unresolvable.
    OP_WITH_SET,     // u16 name; [value, obj] -> [value], with the same recheck
    OP_WITH_METH,    // u16 name; [obj] -> [fn, obj]: a call through a `with`
                     // object takes the object as its receiver
    OP_SETCONST_ERR, // a store to an immutable binding: throws TypeError

    OP_ADD, OP_SUB, OP_MUL, OP_DIV, OP_MOD, OP_POW,
    OP_NEG, OP_TONUM,   // ToNumeric: a BigInt stays one (++ and --)
    OP_TONUMBER,        // ToNumber: unary plus, which a BigInt refuses
    OP_TOSTR,         // ToString (string hint) — template substitutions
    OP_TOPROPKEY,     // ToPropertyKey: a Symbol stays, anything else a string
    OP_INC, OP_DEC,   // ++/-- step, type-appropriate (Number or BigInt)
    OP_NOT, OP_BITNOT, OP_TYPEOF,
    OP_EQ, OP_NEQ, OP_SEQ, OP_SNEQ,
    OP_LT, OP_GT, OP_LE, OP_GE,
    OP_BAND, OP_BOR, OP_BXOR, OP_SHL, OP_SHR, OP_USHR,
    OP_INSTANCEOF, OP_IN,
    OP_HASPRIVATE,   // u16 const idx (private atom); pops obj, pushes #name in obj
    OP_GEN_START,    // a generator body begins: suspend with the parameters bound
    OP_YIELD_DELEGATE,// a yield inside yield*: the resume pushes [input, kind]
    OP_GETPRIVATE,   // u16 const idx; [obj] -> [val]; TypeError when the object lacks it
    OP_SETPRIVATE,   // u16 const idx; [obj, val] -> [val]; TypeError when absent
    OP_GETMETHOD_PRIV,// u16 const idx; [obj] -> [fn, obj]; TypeError when absent

    OP_JUMP,         // u16 target
    OP_JUMPF,        // pop; jump when falsy
    // u16 target: the comparison and the jump that consumes it, in one
    // instruction. A loop test and an `if` are both this pair.
    OP_LT_JF, OP_GT_JF, OP_LE_JF, OP_GE_JF,
    OP_JUMPT,        // pop; jump when truthy
    OP_JF_KEEP,      // falsy: jump, keep; else pop      (&&)
    OP_JT_KEEP,      // truthy: jump, keep; else pop     (||)
    OP_JNN_KEEP,     // not nullish: jump, keep; else pop (??)

    OP_CLOSURE,      // u16 sub-template idx
    OP_CALL,         // u16 argc; stack: fn this args...
    OP_NEW,          // u16 argc; stack: ctor args...
    OP_RETURN,

    // u16 own-property count, or 0 when it is not known: the table is sized
    // once instead of growing as the properties are defined.
    OP_NEWOBJ,
    OP_NEWARR,       // u16 element count popped
    OP_GETPROP,      // u16 const idx (name), u16 cache: the slot the name was found in last (vm.mc, prop_get_ic)
    OP_GETIMPORT,    // u16 const idx (name), u16 const idx (message); a
                     // module import read: the name must be present
    OP_SETPROP,      // u16 const idx, u16 cache; pops obj, keeps value
    OP_DEFMETHOD,    // u16 const idx; like SETPROP but non-enumerable
    OP_DEFPROP_FIXED,// u16 const idx; neither writable, enumerable nor
                     // configurable — a class's `prototype`
    OP_DEFMETHOD_DYN,// [obj, key, fn] pops key+fn, keeps obj
    OP_GETINDEX, OP_SETINDEX,
    OP_GETMETHOD,    // u16 const idx, u16 cache; pops obj, pushes fn then obj
    OP_GETMETHOD_DYN,// pops key, obj; pushes fn then obj
    OP_DELPROP,      // u16 const idx
    OP_DELINDEX,

    OP_TRY_PUSH,     // i32 catch target
    OP_TRY_POP,
    OP_CATCH_ENTER,  // at a catch target: re-throw a return completion instead
                     // of binding it, so only `finally` sees it
    OP_THROW,

    OP_SETPROTO,     // [obj, proto] pops proto, keeps obj
    // Object literals define their own properties rather than assigning them,
    // so an inherited setter (notably __proto__) is not invoked.
    OP_DEFPROP,      // u16 name; [obj, val] pops val, keeps obj
    // u16 name; as DEFPROP, for a key the compiler knows the object has not
    // got: a plain key of an object literal, with no spread or computed key
    // before it and no earlier key of the same name. Such an object is not
    // reachable from user code yet, so it is still extensible and unsealed.
    OP_DEFPROP_NEW,
    OP_DEFPROP_DYN,  // u16 name-it; [obj, key, val] pops key+val, keeps obj
    // Accessor definition. The trailing u16 is 1 when the property is
    // enumerable (object literals) and 0 when it is not (class bodies).
    OP_DEFGETTER,    // u16 name, u16 enum; [obj, fn] pops fn, keeps obj
    OP_DEFSETTER,    // u16 name, u16 enum; [obj, fn] pops fn, keeps obj
    OP_DEFGETTER_DYN,// u16 enum; [obj, key, fn] pops key+fn, keeps obj
    // u16 name, u16 kind; [obj, val] pops val, keeps obj. Installs a private
    // element on the object it belongs to, once: 0 a method, 1 a getter,
    // 2 a setter, 3 a field (the only writable one).
    OP_DEFPRIVATE,
    OP_DEFSETTER_DYN,// u16 enum; [obj, key, fn] pops key+fn, keeps obj
    OP_ARR_APPEND,   // [arr, v] pops v, keeps arr
    OP_ARR_SPREAD,   // [arr, src] pops src; appends elements/chars
    OP_OBJ_SPREAD,   // [obj, src] pops src; copies own props
    OP_OBJ_REST,     // u16 slot of the excluded-keys array; [src] -> rest obj
    OP_ARR_SLICE_FROM, // u16 start; [arr/str] -> new array of the tail
    OP_CALL_ARRAY,   // [fn, this, argsarr] -> result
    OP_NEW_ARRAY,    // [ctor, argsarr] -> instance
    OP_SUPERCALL_ARRAY, // [fn, this, argsarr] -> result, propagating new.target
    OP_JUMP_NULLISH, // u16; top nullish: pop, jump
    OP_JUMP_NULLISH_METH, // u16; peek(1) nullish: pop 2, jump
    OP_CHECK_ITERABLE,   // top must be an array or string
    OP_KEYS,         // [v] -> array of own enumerable key strings

    OP_YIELD,        // suspend the generator frame; top is the value
    OP_AWAIT,        // suspends like OP_YIELD, but marks the reason as await
                     // so an async generator can tell one from the other
    OP_GET_ITER,     // [v] -> iterator via Symbol.iterator
    OP_GET_AITER,    // [v] -> iterator via Symbol.asyncIterator, else Symbol.iterator
    OP_GET_AITER_W,  // [v] -> [iterator, wrapped]: true when it came from Symbol.iterator
    OP_REQUIRE_OBJ,  // [v] -> [v]; TypeError when v is null or undefined
    OP_ITER_CLOSE_ABRUPT, // u16 done slot; as ITER_CLOSE in a handler: a throw
                     // completion keeps its own error over the iterator's
    OP_RETHROW,      // pop; continues the completion a handler caught, a
                     // return completion staying one (THROW is always a throw)
    OP_ITER_SEND,    // [iter, sent] -> [value, done] via iter.next(sent)
    OP_ITER_NEXT,    // [iter] -> [value, done]
    // Array destructuring drives the iterator through these. The u16 operand
    // is the local slot holding the "exhausted" flag, so a spent iterator is
    // never stepped again.
    OP_ITER_STEP,    // u16 done slot; [iter] -> value (undefined once done)
    OP_ITER_REST,    // u16 done slot; [iter] -> array of the remaining values
    OP_ITER_CLOSE,   // u16 done slot; [iter] -> ; calls return() unless done
    // for-await reads next()'s result directly rather than through
    // OP_ITER_NEXT, so it needs the same "must be an object" check.
    OP_ITER_CHECK,   // [result] -> [result]; TypeError if not an object
    // A tagged template's strings array and its .raw are handed to the tag
    // frozen, so a tag cannot alter what a later evaluation of the same site
    // sees.
    OP_FREEZE,       // [obj] -> [obj]; freezes in place
    OP_REGEX,        // u16 source const, u16 flags const -> RegExp object
    OP_DEFGLOBAL,    // u16 const idx; keeps value: a script's top-level
                     // declaration made a global, never a strict-mode error
    OP_PUTLOCAL,     // u16 slot; pops into the slot: a store whose value the
                     // statement discards
    OP_GETPROP_L,    // u16 slot, u16 const idx, u16 cache: GETLOCAL then GETPROP
    OP_GETINDEX_LL,  // u16 slot, u16 slot: two GETLOCALs then GETINDEX
    OP_LT_JF_LL,     // u16 slot, u16 slot, i32 target: two GETLOCALs, LT, jump when false
    OP_GETPROP_THIS, // u16 const idx, u16 cache: THIS then GETPROP
    OP_SEQ_JF,       // i32 target: SEQ then JUMPF
    OP_SNEQ_JF,      // i32 target: SNEQ then JUMPF
    OP_GETUPVALV,    // u16 upvalue index: the value itself, captured as such; a hole refused
    OP_GET_ITER_S,   // u16 done slot; [v] -> [iterator]: a plain array stays itself, the slot its index
    OP_ITER_NEXT_S,  // u16 done slot; [iter] -> [value, done], the slot kept
    OP_PROTOGET,     // u16 const idx (name): `{}.name`, Object.prototype's without the object
    // Pairs the emitter folds as it goes (ch_op, ch_op_u16; the compiler's
    // emit_jumpf and emit_jumpt), chosen from the bytecode profile of
    // bsky.app's load: a dispatch each and the stack traffic between.
    OP_SETPROP_POP,  // u16 const idx, u16 cache: SETPROP then POP
    OP_SETUPVAL_POP, // u16 upvalue index: SETUPVAL then POP
    OP_SETCELL_POP,  // u16 slot: SETCELL then POP
    OP_GETLOCAL_UNDEF,  // u16 slot: GETLOCAL then UNDEF (a call's callee and this)
    OP_GETUPVAL_UNDEF,  // u16 upvalue index: GETUPVAL then UNDEF
    OP_GETUPVALV_UNDEF, // u16 upvalue index: GETUPVALV then UNDEF
    OP_RETURN_UNDEF, // UNDEF then RETURN
    OP_SEQ_NULL, OP_SNEQ_NULL,   // [v] -> [v === null], [v !== null]
    OP_SEQ_UNDEF, OP_SNEQ_UNDEF, // [v] -> [v === undefined], [v !== undefined]
    OP_EQ_NULLISH, OP_NEQ_NULLISH, // [v] -> [v == null], [v != null]
    OP_GETLOCAL_CONST, // u16 slot, u16 const idx: GETLOCAL then CONST
    OP_GETLOCAL2,    // u16 slot, u16 slot: two GETLOCALs
    OP_SEQ_JT, OP_SNEQ_JT,       // i32 target: SEQ then JUMPT, SNEQ then JUMPT
    OP_SEQ_LC_JF,    // u16 slot, u16 const idx, i32 target: GETLOCAL, CONST, SEQ, jump when false
    OP_SEQ_LC_JT,    // u16 slot, u16 const idx, i32 target: the same, jump when true (a switch's case)
    OP_SEQ_NULL_JF, OP_SNEQ_NULL_JF, // i32 target: SEQ_NULL then JUMPF, SNEQ_NULL then JUMPF
    // the register form (doc/PLAN_register_bytecode.md): operands are frame slots
    OP_MOV,          // u16 dst, u16 src: slot = slot
    OP_LOADK,        // u16 dst, u16 const idx: slot = constant
    OP_RJF, OP_RJT,  // u16 slot, i32 target: jump when the slot is falsy, truthy
    // u16 dst, u16 a, u16 b; the I forms an i32 in place of b: dst = a op b
    // on numbers, stepping over the nine-byte stack form of the same that
    // follows, which runs instead for anything else
    OP_RADD, OP_RADDI, OP_RSUB, OP_RSUBI, OP_RMUL, OP_RMULI, OP_RDIV, OP_RDIVI,
    // RBIT and RBITI: u8 kind (RK_BAND..RK_USHR) first, then as above;
    // RBORI and RBANDI: `a | k` and `a & k`, the two a page has most
    OP_RBIT, OP_RBITI, OP_RBORI, OP_RBANDI,
    // u16 a, u16 b, i32 target (the I forms an i32 for b, the K forms a
    // constant's index): jump when a op b is false
    OP_RJLT, OP_RJLTI, OP_RJGT, OP_RJGTI, OP_RJLE, OP_RJLEI, OP_RJGE, OP_RJGEI, OP_RJSEQ, OP_RJSEQK, OP_RJSNEQ, OP_RJSNEQK,
    OP_RJNULLISH, OP_RJNOTNULLISH   // u16 a, u16 unused, i32 target: jump when a == null is false, a != null
}

// RBIT's kinds (doc/PLAN_register_bytecode.md, phase 3).
const i32 RK_BAND = 4;
const i32 RK_BOR = 5;
const i32 RK_BXOR = 6;
const i32 RK_SHL = 7;
const i32 RK_SHR = 8;
const i32 RK_USHR = 9;

struct TmplUpval {
    bool from_parent_slot;   // else from parent's upvalues
    i32 index;
    bool by_value;           // the value itself, not a box: read with OP_GETUPVALV
}

// A function compiled on its first call (compiler.mc, lazy_template): the
// source it is reparsed from, shared by every lazy function of one
// compile, and the upvalues its closures already capture, by name.
// A module's names a lazy function may reach: its imports, read
// through the dependency namespaces, and its exports, written through
// to its own namespace. Strings owned.
struct LazyImport {
    str name;
    str slot_name;
    str prop;
    str spec;
}

struct LazyExport {
    str local;
    str exported;
}

struct LazySource {
    str src;             // owned copies: an embedder may free its text after the run
    str src_name;
    i32* line_starts;    // owned
    i32 n_lines;
    i32 refs;
    i32 compiled;        // the lazy functions of it compiled so far: what the code cache would add
    bool module;
    str ns_name;         // owned; the module's namespace binding
    LazyImport* imports;
    i32 n_imports;
    LazyExport* exports;
    i32 n_exports;
}

str lazy_str(str s) {
    str o;
    o.data = alloc<u8>(s.len > 0 ? s.len : 1);
    memcpy(o.data, s.data, s.len);
    o.len = s.len;
    return o;
}

// The source a cache's lazy functions are reparsed from, with nothing of
// a module: the code cache holds scripts.
LazySource* lazy_source_new(str src, str src_name) {
    LazySource* s = new(LazySource);
    s.src = lazy_str(src);
    s.src_name = lazy_str(src_name);
    i32 n = 1;
    for i32 i = 0; i < src.len; i++ { if *(src.data + i) == '\n' { n++; } }
    s.line_starts = alloc<i32>(n);
    *(s.line_starts) = 0;
    i32 k = 1;
    for i32 i = 0; i < src.len; i++ {
        if *(src.data + i) == '\n' { *(s.line_starts + k) = i + 1; k++; }
    }
    s.n_lines = n;
    return s;
}

void lazy_source_free(LazySource* s) {
    free(s.src.data);
    free(s.src_name.data);
    free(s.line_starts);
    if s.ns_name.data != null { free(s.ns_name.data); }
    for i32 i = 0; i < s.n_imports; i++ {
        LazyImport* m = s.imports + i;
        free(m.name.data); free(m.slot_name.data); free(m.prop.data); free(m.spec.data);
    }
    if s.imports != null { free(s.imports); }
    for i32 i = 0; i < s.n_exports; i++ { free((s.exports + i).local.data); free((s.exports + i).exported.data); }
    if s.exports != null { free(s.exports); }
    free(s);
}

struct LazyUp {
    str name;            // owned
    bool is_const;
    bool tdz;
    bool exported;
    bool by_value;
}

struct LazyFn {
    LazySource* source;
    i32 start;           // the `function` keyword's offset in the source
    bool strict;         // the code around it is strict
    bool self_name;      // a named expression, which binds its own name
    bool method;         // a method: its key comes first
    bool name_inferred;
    LazyUp* ups;
    i32 n_ups;
    u8* names_buf;       // the upvalues' names, one block
}

void lazy_free(LazyFn* lz) {
    if lz.names_buf != null { free(lz.names_buf); }
    if lz.ups != null { free(lz.ups); }
    free(lz);
}

// An entry of a template's property-cache aux table, named by a code in
// IC_AUX..IC_PROTO: an absent name (the chain start it was absent under
// and the prototype epoch then), or two codes for a site that sees two
// layouts (vm.mc, "prop_get_ic").
struct IcAux {
    i32 kind;
    i32 code_a;
    i32 code_b;
    u64 proto;
    u32 epoch;
}

// A plain call builds its frame in the interpreter loop: no rest
// parameter or arguments object, not a class, generator or async body.
const u8 CALL_PLAIN = 1;
const u8 CALL_SLOW = 2;

struct FnTemplate {
    str name;            // owned copy
    i32 n_params;
    i32 arity;           // Function.length: params before the first
                         // default value or rest parameter
    i32 n_slots;
    bool has_rest;       // last param collects surplus arguments
    bool is_gen;         // calls build a generator object
    bool is_async;       // calls build generator state + promise
    bool is_class;       // a class constructor: reachable only via `new`/super()
    bool derived_ctor;   // a derived class constructor: owes a super() call
    bool not_ctor;       // arrow/method/generator/async: `new` is a TypeError
    bool needs_arguments; // references `arguments`; build it at call time
    bool sloppy;         // not strict-mode code: a plain call's `this` is
                         // the global object
    u8 call_shape;       // 0 until the first call of the compiled body,
                         // then CALL_PLAIN or CALL_SLOW (vm.mc, OP_CALL)
    u8* code;
    i32 code_len;
    Value* consts;       // GC-rooted via the VM mark hook
    i32 n_consts;
    u8* catom;           // bit i set: constant i is a name (the code cache re-interns it)
    TmplUpval* upvals;
    i32 n_upvals;
    FnTemplate** subs;
    i32 n_subs;
    PosEntry* pos;       // code_off -> source line/col, for stack traces
    i32 n_pos;
    str src_name;        // source filename (borrowed; owned by the module)
    // The text this function was written as, for Function.prototype.toString.
    // src_text is the whole source, borrowed and outliving the template; the
    // span is this function's slice of it. Empty for a native or a wrapper.
    str src_text;
    i32 src_start;
    i32 src_end;
    // not compiled yet: what compiling it on the first call needs; null after
    LazyFn* lazy;
    // a lazy function's source copy, which its text and its subs' point into;
    // the last template that holds it frees it
    LazySource* owner;
    // what `--prof` charges to this function
    i64 prof_ops;
    i64 prof_ns;
    i32 prof_samples;
    i64 prof_calls;
    i64* prof_allocs;    // its allocations by cell kind, 16 slots, once seen
    IcAux* ic_aux;       // the property cache's entries that need more than a slot
    i32 n_ic_aux;
    i32 ic_aux_cap;
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
    // Where the last instruction's opcode byte went, so the compiler can
    // recognise what it just emitted and fold a pair into one instruction;
    // and the one before it, for a triple.
    i32 last_op;
    i32 prev_op;
    i32 prev2_op;
    // The furthest position any jump has been pointed at. A pair may only be
    // folded when nothing jumps into the second half of it, and a jump patched
    // to the position the second half would occupy is exactly that.
    i32 max_target;
    Vec<Value> consts;
    Vec<i32> atom_ix;    // the constants that are names, for the code cache
    Vec<TmplUpval> upvals;
    Vec<TmplPtr> subs;
    Vec<PosEntry> pos;
}

void chunk_init(Chunk* ch) {
    vec_init<u8>(&ch.code, 64);
    ch.last_op = 0 - 1;
    ch.max_target = 0 - 1;
    vec_lazy<Value>(&ch.consts);
    vec_lazy<i32>(&ch.atom_ix);
    vec_lazy<TmplUpval>(&ch.upvals);
    vec_lazy<TmplPtr>(&ch.subs);
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

// The instruction before the one about to be written, when it is whole,
// nothing jumps to the boundary and its opcode is `want`, rewritten in
// place as `fused`, which stands for both: true when it was.
private bool ch_fuse_last(Chunk* ch, i32 want, i32 len, i32 fused) {
    i32 at = ch.last_op;
    if at < 0 || at != ch.code.len - len || ch.max_target >= ch.code.len { return false; }
    if cast(i32, vec_get(&ch.code, at)) != want { return false; }
    vec_set(&ch.code, at, cast(u8, fused));
    return true;
}

void ch_op(Chunk* ch, i32 op) {
    // a pair the profile shows often becomes one instruction: the first
    // rewritten in place, the second never written
    if op == OP_POP {
        if ch_fuse_last(ch, OP_SETLOCAL, 3, OP_PUTLOCAL) || ch_fuse_last(ch, OP_SETPROP, 5, OP_SETPROP_POP)
           || ch_fuse_last(ch, OP_SETUPVAL, 3, OP_SETUPVAL_POP) || ch_fuse_last(ch, OP_SETCELL, 3, OP_SETCELL_POP) { return; }
    } else if op == OP_UNDEF {
        if ch_fuse_last(ch, OP_GETLOCAL, 3, OP_GETLOCAL_UNDEF) || ch_fuse_last(ch, OP_GETUPVAL, 3, OP_GETUPVAL_UNDEF)
           || ch_fuse_last(ch, OP_GETUPVALV, 3, OP_GETUPVALV_UNDEF) { return; }
    } else if op == OP_RETURN {
        if ch_fuse_last(ch, OP_UNDEF, 1, OP_RETURN_UNDEF) { return; }
    } else if op == OP_SEQ || op == OP_SNEQ {
        if ch_fuse_last(ch, OP_NULL, 1, op == OP_SEQ ? OP_SEQ_NULL : OP_SNEQ_NULL)
           || ch_fuse_last(ch, OP_UNDEF, 1, op == OP_SEQ ? OP_SEQ_UNDEF : OP_SNEQ_UNDEF) { return; }
    } else if op == OP_EQ || op == OP_NEQ {
        if ch_fuse_last(ch, OP_NULL, 1, op == OP_EQ ? OP_EQ_NULLISH : OP_NEQ_NULLISH)
           || ch_fuse_last(ch, OP_UNDEF, 1, op == OP_EQ ? OP_EQ_NULLISH : OP_NEQ_NULLISH) { return; }
    }
    ch.prev2_op = ch.prev_op;
    ch.prev_op = ch.last_op;
    ch.last_op = ch.code.len;
    vec_push(&ch.code, cast(u8, op));
}

void ch_u16(Chunk* ch, i32 v) {
    vec_push(&ch.code, cast(u8, v));
    vec_push(&ch.code, cast(u8, v >> 8));
}

void ch_op_u16(Chunk* ch, i32 op, i32 v) {
    // a local and a constant, or two locals, loaded as one instruction
    if (op == OP_CONST || op == OP_GETLOCAL) && ch_fuse_last(ch, OP_GETLOCAL, 3, op == OP_CONST ? OP_GETLOCAL_CONST : OP_GETLOCAL2) {
        ch_u16(ch, v);
        return;
    }
    ch_op(ch, op);
    ch_u16(ch, v);
}

// The property cache is empty when written; the interpreter fills it.
const i32 IC_EMPTY = 0xFFFF;
// A property instruction with its name and an empty cache after it.
void ch_op_ic(Chunk* ch, i32 op, i32 name) {
    ch_op_u16(ch, op, name);
    ch_u16(ch, IC_EMPTY);
}

i32 ch_add_const(Chunk* ch, Value v) {
    vec_push(&ch.consts, v);
    return ch.consts.len - 1;
}

// A name as a constant: the atom's number, which the code cache writes
// as the name since the numbers are per run.
i32 ch_add_const_atom(Chunk* ch, u32 a) {
    vec_push(&ch.atom_ix, ch.consts.len);
    return ch_add_const(ch, value_int(cast(i32, a)));
}

// A code position, as every jump carries it: four bytes, so a function's
// code may pass 64 KB (a bundle's data literal in one function does).
void ch_target(Chunk* ch, i32 v) {
    vec_push(&ch.code, cast(u8, v));
    vec_push(&ch.code, cast(u8, v >> 8));
    vec_push(&ch.code, cast(u8, v >> 16));
    vec_push(&ch.code, cast(u8, v >> 24));
}

// A jump to a position already known (a loop's start).
void ch_op_target(Chunk* ch, i32 op, i32 target) {
    ch_op(ch, op);
    ch_target(ch, target);
}

// Emits a jump with a placeholder target; returns the patch position.
i32 ch_jump(Chunk* ch, i32 op) {
    ch_op(ch, op);
    i32 at = ch.code.len;
    ch_target(ch, -1);
    return at;
}

void ch_patch(Chunk* ch, i32 at) { ch_patch_to(ch, at, ch.code.len); }

void ch_patch_to(Chunk* ch, i32 at, i32 target) {
    if target > ch.max_target { ch.max_target = target; }
    vec_set(&ch.code, at, cast(u8, target));
    vec_set(&ch.code, at + 1, cast(u8, target >> 8));
    vec_set(&ch.code, at + 2, cast(u8, target >> 16));
    vec_set(&ch.code, at + 3, cast(u8, target >> 24));
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
    t.prof_ops = 0;
    t.prof_ns = 0;
    t.prof_samples = 0;
    t.prof_calls = 0;
    t.prof_allocs = null;
    t.src_text.data = null;
    t.src_text.len = 0;
    t.src_start = 0;
    t.src_end = 0;
    t.has_rest = has_rest;
    t.is_gen = is_gen;
    t.is_async = is_async;
    t.is_class = false;
    t.derived_ctor = false;
    t.not_ctor = is_gen || is_async;
    t.sloppy = false;
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
    if ch.atom_ix.len > 0 {
        i32 nb = (t.n_consts + 7) / 8;
        t.catom = alloc<u8>(nb);
        for i32 i = 0; i < nb; i++ { *(t.catom + i) = 0; }
        for i32 i = 0; i < ch.atom_ix.len; i++ {
            i32 ix = vec_get(&ch.atom_ix, i);
            *(t.catom + (ix >> 3)) |= cast(u8, 1 << (ix & 7));
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
    vec_free(&ch.atom_ix);
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

// An empty template with its name, the shape the code cache fills.
FnTemplate* template_new(str name, i32 n_params, i32 n_slots) {
    FnTemplate* t = new(FnTemplate);
    if name.len > 0 {
        u8* nb = alloc<u8>(name.len);
        memcpy(nb, name.data, name.len);
        t.name.data = nb;
        t.name.len = name.len;
    }
    t.n_params = n_params;
    t.arity = n_params;
    t.n_slots = n_slots;
    t.code = alloc<u8>(1);
    return t;
}

void template_free(FnTemplate* t) {
    if t.lazy != null { lazy_free(t.lazy); t.lazy = null; }
    for i32 i = 0; i < t.n_subs; i++ {
        template_free(*(t.subs + i));
    }
    if t.name.data != null { free(t.name.data); }
    free(t.code);
    if t.consts != null { free(t.consts); }
    if t.catom != null { free(t.catom); }
    if t.ic_aux != null { free(t.ic_aux); }
    if t.upvals != null { free(t.upvals); }
    if t.subs != null { free(t.subs); }
    if t.pos != null { free(t.pos); }
    if t.prof_allocs != null { free(t.prof_allocs); }
    LazySource* owner = t.owner;
    free(t);
    if owner != null { owner.refs--; if owner.refs == 0 { lazy_source_free(owner); } }
}

// vm.mc — bytecode interpreter: frames, dispatch, coercions, natives.
//
// Values live on one stack; frames index into it. Any allocation can
// collect, so operands stay on the stack until results exist. The
// pipeline entry vm_run_source drives parse → lower → compile → run.

import vec;
import str;
import map;
import diag;
import value;
import gc;
import atom;
import object;
import ustr;
import bigint;
import os_time;
import net;
import bytecode;
import ast;
import bump;
import parser;
import lower;
import compiler;
import math;
import format_f64;
import regex;

type RegexProgPtr = RegexProg*;

// Direct JS recursion grows the frames array, not the C stack, so it
// can go deep. Native re-entry (a native calling back into JS) grows
// the real C stack per level, so it is capped much lower.
const i32 VM_STACK_MAX = 262144;
const i32 VM_FRAMES_MAX = 8000;
const i32 VM_HANDLERS_MAX = 4096;
const i32 VM_EXEC_DEPTH_MAX = 120;

struct Frame {
    JsFunction* fun;    // null for the script frame
    FnTemplate* tmpl;
    i32 ret_ip;
    i32 cur_ip;         // this frame's active site (call/throw), for stacks
    i32 base;
    Value this_val;
    Value arguments_obj;  // the `arguments` object, or undefined if unused
    Value new_target;   // new.target: the constructor, or undefined; super() propagates it
    bool is_ctor;
    JsGenerator* gen;   // non-null while running a generator/async body
}

struct Handler {
    i32 frame_count;
    i32 sp;
    i32 ip;
}

const i32 JOB_REACTION = 0;    // a=handler, b=arg, c=promise2
const i32 JOB_ASYNC_STEP = 1;  // a=generator, b=result promise, c=input
const i32 JOB_THENABLE = 2;    // a=thenable, b=promise it resolves

struct VmJob {
    i32 kind;
    bool flag;      // reject path / throw resume
    Value a;
    Value b;
    Value c;
}

struct VmTimer {
    i32 id;
    bool alive;
    bool reffed;  // an unreffed timer fires, but does not hold the loop open
    f64 due;      // absolute deadline, milliseconds on the monotonic clock
    f64 delay;    // what refresh() re-arms from
    f64 period;   // > 0 for setInterval: rearmed this far ahead after firing
    i64 seq;
    Value cb;
    Value args;   // extra arguments to hand the callback, or undefined
}

// An I/O handle keeps the reactor alive while open (Node's ref/unref) and
// is the dispatch target for socket events. Dormant in M31 (nothing
// registers one yet); the fd/kind/interest fields are filled in M32 when
// real sockets arrive.
struct IoHandle {
    i64 fd;         // OS socket; -1 while unused
    i32 kind;       // 0 = none (M32: listener / connecting / connected)
    i16 interest;   // poll readiness mask (NET_POLLIN/OUT); 0 = not polled
    bool reffed;    // does this handle keep the loop alive?
    bool alive;     // false once closed; slots are cleared between runs
    Value owner;    // JS Socket/Server object; GC-marked, dispatch target
    void* ext;      // native side-state (e.g. a TLS session); not GC-traced
}

// Called by the reactor for each ready handle: (vm, handle index, revents).
// The `net` module installs the implementation, keeping vm.mc free of any
// dependency on builtins.
type ReactorHook = fn(VM*, i32, i16): void;

// Dynamic import — `import(spec)` — evaluated by the module layer. Installed
// there, so vm.mc stays free of the module/loader machinery. Takes (spec,
// referrer path) and returns a promise of the module namespace.
type DynImportHook = fn(VM*, Value, Value): Value;

// Builds the `arguments` object from a call's argument values, installed by
// builtins so vm.mc's call sites stay free of the object/iterator builtins.
type ArgumentsBuilder = fn(VM*, Value*, i32): Value;

struct VM {
    GcHeap heap;
    AtomTable atoms;
    Value* stack;
    i32 sp;
    Frame* frames;
    i32 fp;
    Value pending_new_target;  // new.target for the next vm_call_stack frame
    Handler* handlers;
    i32 hp;
    IntMap<Value> globals;
    // The entry file's module object, for require.main. Node's entry is a
    // module like any other; here it is a script, so this stands in for it.
    JsObject* main_module;
    // Bindings stored in the globals table that the global object must not
    // report. In node these are module-scoped, so a bare `__dirname` resolves
    // while `globalThis.__dirname` is undefined; tsmc keeps them in the one
    // table, so the distinction is made here instead.
    u32[4] hidden_globals;
    i32 n_hidden_globals;
    Vec<TmplPtr> troots;   // owned root templates; consts are GC roots
    Value pending;
    bool has_pending;
    bool unwind_return;   // the pending value is a return completion, not a throw
    bool quiet_errors;    // suppress diagnostic/uncaught printing (embedders running expected-failure sources)
    u32 atom_length;
    u32 atom_prototype;
    u32 atom_name;
    u32 atom_message;
    // well-known prototypes; null until builtins_install
    JsObject* object_proto;
    JsObject* array_proto;
    JsObject* string_proto;
    JsObject* number_proto;
    JsObject* boolean_proto;
    JsObject* function_proto;
    JsObject*[8] error_protos;   // indexed by ERR_* (size = ERR_KIND_COUNT)
    u64 rng;
    JsObject* generator_proto;
    JsObject* async_generator_proto;
    JsObject* iterator_proto;      // shared by every iterator: the helpers live here
    JsObject* iter_helper_proto;   // what map/filter/take/drop/flatMap return
    JsObject* promise_proto;
    JsObject* regexp_proto;
    JsObject* map_proto;
    JsObject* set_proto;
    JsObject* weakmap_proto;
    JsObject* weakset_proto;
    JsObject* date_proto;
    JsObject* symbol_proto;
    JsObject* symbol_registry;   // Symbol.for/keyFor: string key -> symbol
    JsObject* bigint_proto;
    JsObject* buffer_proto;
    JsObject* textenc_proto;
    JsObject* textdec_proto;
    JsObject* timeout_proto;
    JsObject* ta_proto;        // %TypedArray%.prototype (shared methods)
    JsObject* arraybuffer_proto;
    JsObject* dataview_proto;
    JsObject*[9] ta_protos;    // per-kind TypedArray.prototype (instanceof)
    u32 atom_ta_off;
    u32 atom_ta_len;
    u32 atom_ta_kind;
    JsObject* node_fs_ns;      // built-in `fs` module namespace (lazy)
    JsObject* node_fsp_ns;     // built-in `fs/promises` module namespace (lazy)
    JsObject* node_path_ns;    // built-in `path` module namespace (lazy)
    JsObject* node_os_ns;      // built-in `os` module namespace (lazy)
    JsObject* node_events_ns;  // built-in `events` module namespace (lazy)
    JsObject* node_util_ns;    // built-in `util` module namespace (lazy)
    JsObject* node_crypto_ns;  // built-in `crypto` module namespace (lazy)
    JsObject* node_zlib_ns;    // built-in `zlib` module namespace (lazy)
    JsObject* node_process_ns; // built-in `process` module namespace (lazy)
    JsObject* node_buffer_ns;  // built-in `buffer` module namespace (lazy)
    JsObject* node_timers_ns;  // built-in `timers` module namespace (lazy)
    JsObject* crypto_hash_proto;   // Hash.prototype for createHash
    JsObject* crypto_hmac_proto;   // Hmac.prototype for createHmac
    JsObject* url_proto;
    JsObject* usp_proto;       // URLSearchParams.prototype
    JsObject* require_cache;    // CommonJS module cache: canon path -> module obj
    Vec<RegexProgPtr> regexps;
    u32 atom_rx;
    u32 atom_source;
    u32 atom_flags;
    u32 atom_lastindex;
    u32 atom_index;
    Vec<VmJob> jobs;         // microtask FIFO (head index avoids shifting)
    i32 job_head;
    Vec<Value> rejections;   // promises rejected with no handler at reject time
    Vec<VmTimer> timers;
    i32 next_timer_id;
    i64 timer_seq;
    Vec<IoHandle> handles;   // live I/O handles; keep the reactor alive
    ReactorHook reactor_hook;   // net module's ready-handle dispatcher, or null
    DynImportHook dynimport_hook;   // module layer's import(spec), or null
    void* esm_loader;           // persistent ESM Loader for dynamic import, or null
    ArgumentsBuilder arguments_builder;   // builds `arguments`, or null
    Vec<Value> symbols;      // registry: id - 0x80000000 -> symbol cell
    Value sym_iterator;      // well-known Symbol.iterator
    u32 sym_iterator_id;
    Value sym_to_primitive;  // well-known Symbol.toPrimitive
    u32 sym_to_primitive_id;
    Value sym_async_iterator; // well-known Symbol.asyncIterator
    u32 sym_async_iterator_id;
    Value sym_to_string_tag; // well-known Symbol.toStringTag
    u32 sym_to_string_tag_id;
    Value sym_has_instance;  // well-known Symbol.hasInstance
    u32 sym_has_instance_id;
    u32 atom_pstate;
    u32 atom_pvalue;
    u32 atom_pcbs;
    u32 atom_phandled;
    u32 atom_value;
    u32 atom_done;
    u32 atom_next;
    i32 exec_depth;   // nested vm_execute invocations (C-stack guard)
}

const i32 ERR_ERROR = 0;
const i32 ERR_TYPE = 1;
const i32 ERR_RANGE = 2;
const i32 ERR_REF = 3;
const i32 ERR_SYNTAX = 4;
const i32 ERR_EVAL = 5;
const i32 ERR_URI = 6;
const i32 ERR_AGGREGATE = 7;
const i32 ERR_KIND_COUNT = 8;   // must match the error_protos array size

str vm_error_kind_name(i32 kind) {
    if kind == ERR_TYPE { return "TypeError"; }
    if kind == ERR_RANGE { return "RangeError"; }
    if kind == ERR_REF { return "ReferenceError"; }
    if kind == ERR_SYNTAX { return "SyntaxError"; }
    if kind == ERR_EVAL { return "EvalError"; }
    if kind == ERR_URI { return "URIError"; }
    if kind == ERR_AGGREGATE { return "AggregateError"; }
    return "Error";
}

// --- roots -----------------------------------------------------------

private void mark_template(GcHeap* h, FnTemplate* t) {
    for i32 i = 0; i < t.n_consts; i++ {
        gc_mark_value(h, *(t.consts + i));
    }
    for i32 i = 0; i < t.n_subs; i++ {
        mark_template(h, *(t.subs + i));
    }
}

// Ephemeron pass: for every live WeakMap/WeakSet, mark the value of each
// entry whose key survived. Returns true if it marked anything new, so
// the collector loops it (a value may itself be another map's key).
private bool vm_weak_mark(GcHeap* h, void* ctx) {
    bool any = false;
    GcCell* c = h.all;
    while c != null {
        if c.mark != 0 && c.kind == GC_MAP {
            JsMap* m = cast(JsMap*, c);
            if m.weak {
                for i32 i = 0; i < m.len; i++ {
                    if *(m.live + i) {
                        Value k = *(m.keys + i);
                        if value_is_cell(k) && value_as_cell(k).mark != 0 {
                            Value v = *(m.vals + i);
                            if value_is_cell(v) && value_as_cell(v).mark == 0 {
                                gc_mark_value(h, v);
                                any = true;
                            }
                        }
                    }
                }
            }
        }
        c = c.next;
    }
    return any;
}

// Drops entries whose key did not survive marking, from every live weak
// collection. Runs before the sweep, while marks are still valid.
private void vm_weak_sweep(GcHeap* h, void* ctx) {
    GcCell* c = h.all;
    while c != null {
        if c.mark != 0 && c.kind == GC_MAP {
            JsMap* m = cast(JsMap*, c);
            if m.weak {
                for i32 i = 0; i < m.len; i++ {
                    if *(m.live + i) {
                        Value k = *(m.keys + i);
                        if !value_is_cell(k) || value_as_cell(k).mark == 0 {
                            *(m.live + i) = false;
                            m.count--;
                        }
                    }
                }
            }
        }
        c = c.next;
    }
}

private void vm_mark_roots(GcHeap* h, void* ctx) {
    VM* vm = cast(VM*, ctx);
    gc_mark_value(h, vm.pending_new_target);
    for i32 i = 0; i < vm.sp; i++ {
        gc_mark_value(h, *(vm.stack + i));
    }
    for i32 i = 0; i < vm.fp; i++ {
        Frame* fr = vm.frames + i;
        if fr.fun != null { gc_mark_cell(h, &fr.fun.head); }
        gc_mark_value(h, fr.this_val);
        gc_mark_value(h, fr.arguments_obj);
        gc_mark_value(h, fr.new_target);
    }
    for i32 i = 0; i < vm.globals.cap; i++ {
        IntSlot<Value>* sl = vm.globals.slots + i;
        if sl.state == SLOT_USED { gc_mark_value(h, sl.val); }
    }
    for i32 i = 0; i < vm.troots.len; i++ {
        mark_template(h, vec_get(&vm.troots, i));
    }
    if vm.object_proto != null { gc_mark_cell(h, &vm.object_proto.head); }
    if vm.array_proto != null { gc_mark_cell(h, &vm.array_proto.head); }
    if vm.string_proto != null { gc_mark_cell(h, &vm.string_proto.head); }
    if vm.number_proto != null { gc_mark_cell(h, &vm.number_proto.head); }
    if vm.boolean_proto != null { gc_mark_cell(h, &vm.boolean_proto.head); }
    if vm.function_proto != null { gc_mark_cell(h, &vm.function_proto.head); }
    for i32 i = 0; i < ERR_KIND_COUNT; i++ {
        if vm.error_protos[i] != null { gc_mark_cell(h, &vm.error_protos[i].head); }
    }
    if vm.generator_proto != null { gc_mark_cell(h, &vm.generator_proto.head); }
    if vm.async_generator_proto != null { gc_mark_cell(h, &vm.async_generator_proto.head); }
    if vm.iterator_proto != null { gc_mark_cell(h, &vm.iterator_proto.head); }
    if vm.iter_helper_proto != null { gc_mark_cell(h, &vm.iter_helper_proto.head); }
    if vm.promise_proto != null { gc_mark_cell(h, &vm.promise_proto.head); }
    if vm.regexp_proto != null { gc_mark_cell(h, &vm.regexp_proto.head); }
    if vm.map_proto != null { gc_mark_cell(h, &vm.map_proto.head); }
    if vm.weakmap_proto != null { gc_mark_cell(h, &vm.weakmap_proto.head); }
    if vm.weakset_proto != null { gc_mark_cell(h, &vm.weakset_proto.head); }
    if vm.symbol_proto != null { gc_mark_cell(h, &vm.symbol_proto.head); }
    if vm.symbol_registry != null { gc_mark_cell(h, &vm.symbol_registry.head); }
    if vm.bigint_proto != null { gc_mark_cell(h, &vm.bigint_proto.head); }
    if vm.set_proto != null { gc_mark_cell(h, &vm.set_proto.head); }
    if vm.date_proto != null { gc_mark_cell(h, &vm.date_proto.head); }
    if vm.buffer_proto != null { gc_mark_cell(h, &vm.buffer_proto.head); }
    if vm.ta_proto != null { gc_mark_cell(h, &vm.ta_proto.head); }
    if vm.arraybuffer_proto != null { gc_mark_cell(h, &vm.arraybuffer_proto.head); }
    if vm.dataview_proto != null { gc_mark_cell(h, &vm.dataview_proto.head); }
    for i32 i = 0; i < 9; i++ {
        if vm.ta_protos[i] != null { gc_mark_cell(h, &vm.ta_protos[i].head); }
    }
    if vm.textenc_proto != null { gc_mark_cell(h, &vm.textenc_proto.head); }
    if vm.textdec_proto != null { gc_mark_cell(h, &vm.textdec_proto.head); }
    if vm.timeout_proto != null { gc_mark_cell(h, &vm.timeout_proto.head); }
    if vm.node_fs_ns != null { gc_mark_cell(h, &vm.node_fs_ns.head); }
    if vm.node_fsp_ns != null { gc_mark_cell(h, &vm.node_fsp_ns.head); }
    if vm.node_path_ns != null { gc_mark_cell(h, &vm.node_path_ns.head); }
    if vm.node_os_ns != null { gc_mark_cell(h, &vm.node_os_ns.head); }
    if vm.node_events_ns != null { gc_mark_cell(h, &vm.node_events_ns.head); }
    if vm.node_util_ns != null { gc_mark_cell(h, &vm.node_util_ns.head); }
    if vm.node_crypto_ns != null { gc_mark_cell(h, &vm.node_crypto_ns.head); }
    if vm.node_zlib_ns != null { gc_mark_cell(h, &vm.node_zlib_ns.head); }
    if vm.node_process_ns != null { gc_mark_cell(h, &vm.node_process_ns.head); }
    if vm.node_buffer_ns != null { gc_mark_cell(h, &vm.node_buffer_ns.head); }
    if vm.node_timers_ns != null { gc_mark_cell(h, &vm.node_timers_ns.head); }
    if vm.crypto_hash_proto != null { gc_mark_cell(h, &vm.crypto_hash_proto.head); }
    if vm.crypto_hmac_proto != null { gc_mark_cell(h, &vm.crypto_hmac_proto.head); }
    if vm.url_proto != null { gc_mark_cell(h, &vm.url_proto.head); }
    if vm.usp_proto != null { gc_mark_cell(h, &vm.usp_proto.head); }
    if vm.require_cache != null { gc_mark_cell(h, &vm.require_cache.head); }
    if vm.main_module != null { gc_mark_cell(h, &vm.main_module.head); }
    for i32 i = vm.job_head; i < vm.jobs.len; i++ {
        VmJob* j = vm.jobs.data + i;
        gc_mark_value(h, j.a);
        gc_mark_value(h, j.b);
        gc_mark_value(h, j.c);
    }
    for i32 i = 0; i < vm.rejections.len; i++ {
        gc_mark_value(h, vec_get(&vm.rejections, i));
    }
    for i32 i = 0; i < vm.timers.len; i++ {
        gc_mark_value(h, (vm.timers.data + i).cb);
        gc_mark_value(h, (vm.timers.data + i).args);
    }
    for i32 i = 0; i < vm.handles.len; i++ {
        IoHandle* hd = vm.handles.data + i;
        if hd.alive { gc_mark_value(h, hd.owner); }
    }
    for i32 i = 0; i < vm.symbols.len; i++ {
        gc_mark_value(h, vec_get(&vm.symbols, i));
    }
    gc_mark_value(h, vm.sym_iterator);
    gc_mark_value(h, vm.sym_to_primitive);
    gc_mark_value(h, vm.sym_async_iterator);
    gc_mark_value(h, vm.sym_to_string_tag);
    gc_mark_value(h, vm.sym_has_instance);
    for i32 i = 0; i < vm.fp; i++ {
        Frame* fr = vm.frames + i;
        if fr.gen != null { gc_mark_cell(h, &fr.gen.head); }
    }
    if vm.has_pending { gc_mark_value(h, vm.pending); }
}

// --- stack helpers -----------------------------------------------------

private void vpush(VM* vm, Value v) {
    *(vm.stack + vm.sp) = v;
    vm.sp++;
}

private Value vpop(VM* vm) {
    vm.sp--;
    return *(vm.stack + vm.sp);
}

private Value vpeek(VM* vm, i32 n) {
    return *(vm.stack + vm.sp - 1 - n);
}

// --- coercions -----------------------------------------------------------

bool js_truthy(Value v) {
    if value_is_int(v) { return value_as_int(v) != 0; }
    if value_is_double(v) {
        f64 d = value_as_f64(v);
        return d == d && d != 0.0;
    }
    if value_is_bool(v) { return value_is_true(v); }
    if value_is_undefined(v) || value_is_null(v) || value_is_hole(v) { return false; }
    if value_is_string(v) { return value_as_string(v).len > 0; }
    if value_is_bigint(v) { return value_as_bigint(v).nlimbs != 0; }
    return true;
}

private i32 f64_to_i32(f64 v) {
    if v != v { return 0; }
    return cast(i32, cast(i64, v));
}

// Bytes of the whitespace run starting at i, or 0. Covers the whole of the
// spec's StrWhiteSpace, not just the ASCII blanks: NBSP, the BOM, the line
// separators and the Zs category all count when converting a string.
i32 js_ws_len(str s, i32 i) {
    u8 c = *(s.data + i);
    if c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == 11 || c == 12 { return 1; }
    if c == 0xC2 && i + 1 < s.len && *(s.data + i + 1) == 0xA0 { return 2; }      // NBSP
    if i + 2 >= s.len { return 0; }
    u8 d = *(s.data + i + 1);
    u8 e = *(s.data + i + 2);
    if c == 0xEF && d == 0xBB && e == 0xBF { return 3; }                          // BOM
    if c == 0xE1 && d == 0x9A && e == 0x80 { return 3; }                          // U+1680
    if c == 0xE3 && d == 0x80 && e == 0x80 { return 3; }                          // U+3000
    if c == 0xE2 {
        // U+2000..U+200A, U+2028, U+2029, U+202F, U+205F
        if d == 0x80 && ((e >= 0x80 && e <= 0x8A) || e == 0xA8 || e == 0xA9 || e == 0xAF) { return 3; }
        if d == 0x81 && e == 0x9F { return 3; }
    }
    return 0;
}

private f64 vm_str_to_num(str s) {
    i32 a = 0;
    i32 b = s.len;
    while a < b {
        i32 w = js_ws_len(s, a);
        if w == 0 { break; }
        a += w;
    }
    while b > a {
        i32 tw = 0;
        if js_ws_len(s, b - 1) == 1 { tw = 1; }
        else if b - 2 >= a && js_ws_len(s, b - 2) == 2 { tw = 2; }
        else if b - 3 >= a && js_ws_len(s, b - 3) == 3 { tw = 3; }
        if tw > 0 {
            b -= tw;
        } else {
            break;
        }
    }
    if a == b { return 0.0; }
    f64 sign = 1.0;
    u8 c0 = *(s.data + a);
    if c0 == '-' { sign = -1.0; a++; }
    else if c0 == '+' { a++; }
    if a == b { return 0.0 / 0.0; }
    // Infinity
    if b - a == 8 && *(s.data + a) == 'I' {
        str inf;
        inf.data = s.data + a;
        inf.len = 8;
        if str_equal(inf, "Infinity") { return sign * (1.0e308 * 10.0); }
    }
    // hex
    if b - a > 2 && *(s.data + a) == '0'
        && (*(s.data + a + 1) == 'x' || *(s.data + a + 1) == 'X') {
        f64 v = 0.0;
        for i32 i = a + 2; i < b; i++ {
            u8 c = *(s.data + i);
            i32 d = -1;
            if c >= '0' && c <= '9' { d = c - '0'; }
            else if c >= 'a' && c <= 'f' { d = c - 'a' + 10; }
            else if c >= 'A' && c <= 'F' { d = c - 'A' + 10; }
            if d < 0 { return 0.0 / 0.0; }
            v = v * 16.0 + d;
        }
        return sign * v;
    }
    // binary (0b) and octal (0o)
    if b - a > 2 && *(s.data + a) == '0' {
        u8 pre = *(s.data + a + 1);
        f64 base = 0.0;
        i32 maxd = 0;
        if pre == 'b' || pre == 'B' { base = 2.0; maxd = 1; }
        else if pre == 'o' || pre == 'O' { base = 8.0; maxd = 7; }
        if base != 0.0 {
            f64 v = 0.0;
            for i32 i = a + 2; i < b; i++ {
                i32 d = *(s.data + i) - '0';
                if d < 0 || d > maxd { return 0.0 / 0.0; }
                v = v * base + cast(f64, d);
            }
            return sign * v;
        }
    }
    // decimal
    u64 mant = 0;
    i32 sig = 0;
    i32 exp_adj = 0;
    i32 n_digits = 0;
    i32 i = a;
    while i < b {
        u8 c = *(s.data + i);
        if !(c >= '0' && c <= '9') { break; }
        if sig < 19 {
            u64 d = c - '0';
            mant = mant * 10 + d;
            if mant != 0 { sig++; }
        } else {
            exp_adj++;
        }
        n_digits++;
        i++;
    }
    if i < b && *(s.data + i) == '.' {
        i++;
        while i < b {
            u8 c = *(s.data + i);
            if !(c >= '0' && c <= '9') { break; }
            if sig < 19 {
                u64 d = c - '0';
                mant = mant * 10 + d;
                if mant != 0 { sig++; }
                exp_adj--;
            }
            n_digits++;
            i++;
        }
    }
    if n_digits == 0 { return 0.0 / 0.0; }
    if i < b && (*(s.data + i) == 'e' || *(s.data + i) == 'E') {
        i++;
        f64 esign = 1.0;
        if i < b && (*(s.data + i) == '+' || *(s.data + i) == '-') {
            if *(s.data + i) == '-' { esign = -1.0; }
            i++;
        }
        i32 ev = 0;
        i32 ed = 0;
        while i < b {
            u8 c = *(s.data + i);
            if !(c >= '0' && c <= '9') { break; }
            i32 dd = c - '0';
            if ev < 1000000 { ev = ev * 10 + dd; }
            ed++;
            i++;
        }
        if ed == 0 { return 0.0 / 0.0; }
        if esign < 0.0 { exp_adj -= ev; } else { exp_adj += ev; }
    }
    if i != b { return 0.0 / 0.0; }
    f64 v = cast(f64, mant) * pow(10.0, exp_adj);
    return sign * v;
}

f64 js_to_number(Value v) {
    if value_is_int(v) { return value_as_int(v); }
    if value_is_double(v) { return value_as_f64(v); }
    if value_is_bool(v) { return value_is_true(v) ? 1.0 : 0.0; }
    if value_is_null(v) { return 0.0; }
    if value_is_string(v) { return vm_str_to_num(gc_string_view(value_as_string(v))); }
    return 0.0 / 0.0;   // undefined, objects (ToPrimitive deferred)
}

// ToPrimitive hints (ES 7.1.1). "default" and "number" share the ordinary
// valueOf-first order; they differ only for Symbol.toPrimitive and Date.
const i32 HINT_DEFAULT = 0;
const i32 HINT_STRING = 1;
const i32 HINT_NUMBER = 2;

// ToNumber (ES 7.1.4). Objects are ToPrimitive'd with the number hint
// first (so unary +/-, bitwise, etc. consult valueOf/Symbol.toPrimitive);
// a Symbol throws. On a thrown coercion the caller sees NaN and unwinds
// via has_pending.
f64 vm_to_number(VM* vm, Value v) {
    if value_is_symbol(v) {
        vm_throw_error(vm, ERR_TYPE, "Cannot convert a Symbol value to a number");
        return 0.0 / 0.0;
    }
    if !value_is_primitive(v) {
        Value p;
        if !vm_to_primitive(vm, v, HINT_NUMBER, &p) { return 0.0 / 0.0; }
        if value_is_symbol(p) {
            vm_throw_error(vm, ERR_TYPE, "Cannot convert a Symbol value to a number");
            return 0.0 / 0.0;
        }
        return js_to_number(p);
    }
    return js_to_number(v);
}

private Value num_norm(f64 v) {
    i32 i = cast(i32, v);
    if cast(f64, i) == v {
        if v == 0.0 && 1.0 / v < 0.0 { return value_number(v); }
        return value_int(i);
    }
    return value_number(v);
}

// Fills `lit` with a borrowed constant for special values and returns
// true; otherwise the caller must format `v` with the owned path.
private bool num_special(f64 v, str* lit) {
    if v != v { *lit = "NaN"; return true; }
    if v == 1.0e308 * 10.0 { *lit = "Infinity"; return true; }
    if v == -1.0e308 * 10.0 { *lit = "-Infinity"; return true; }
    if v == 0.0 { *lit = "0"; return true; }   // ±0
    return false;
}

// Owned decimal string for a finite, non-zero number, matching
// ECMAScript Number::toString (7.1.12.1): shortest digits from Ryu,
// placed per the spec — plain decimal for -6 < n <= 21, else
// exponential with e+/e- notation.
private string js_num_format(f64 v) {
    bool neg = v < 0.0;
    f64 av = neg ? -v : v;

    // small integers: exact and cheap
    i64 iv = cast(i64, av);
    if cast(f64, iv) == av && av < 1.0e15 {
        return neg ? format("-{}", iv) : format("{}", iv);
    }

    // shortest round-trip digits from Ryu, then re-place the point
    string fs = format_f64(av);
    str f = fs;
    // split mantissa / exponent
    i32 epos = -1;
    for i32 i = 0; i < f.len; i++ {
        u8 c = *(f.data + i);
        if c == 'e' || c == 'E' { epos = i; break; }
    }
    i32 e_extra = 0;
    i32 base_end = f.len;
    if epos >= 0 {
        base_end = epos;
        i32 sign = 1;
        i32 j = epos + 1;
        if j < f.len && (*(f.data + j) == '+' || *(f.data + j) == '-') {
            if *(f.data + j) == '-' { sign = -1; }
            j++;
        }
        i32 ev = 0;
        while j < f.len {
            i32 dc = *(f.data + j);
            ev = ev * 10 + (dc - '0');
            j++;
        }
        e_extra = sign * ev;
    }
    // digits of the mantissa and the point position within them
    u8[40] digits;
    i32 nd = 0;
    i32 point = -1;
    for i32 i = 0; i < base_end; i++ {
        u8 c = *(f.data + i);
        if c == '.' {
            point = nd;
        } else if c >= '0' && c <= '9' {
            if nd < 40 { digits[nd] = c; nd++; }
        }
    }
    if point < 0 { point = nd; }
    // ES's n: digits to the left of the decimal point after the exp shift
    i32 n = point + e_extra;
    // strip leading zeros
    i32 start = 0;
    while start < nd - 1 && digits[start] == '0' { start++; n--; }
    // strip trailing zeros
    i32 end = nd;
    while end > start + 1 && digits[end - 1] == '0' { end--; }
    i32 k = end - start;
    free(fs);

    str_buf sb;
    str_buf_init(&sb);
    if neg { str_buf_add(&sb, "-"); }
    str s;
    s.data = &digits[start];
    s.len = k;

    if k <= n && n <= 21 {
        str_buf_add(&sb, s);
        for i32 i = 0; i < n - k; i++ { str_buf_add(&sb, "0"); }
    } else if 0 < n && n <= 21 {
        str head;
        head.data = &digits[start];
        head.len = n;
        str tail;
        tail.data = &digits[start + n];
        tail.len = k - n;
        str_buf_add(&sb, head);
        str_buf_add(&sb, ".");
        str_buf_add(&sb, tail);
    } else if -6 < n && n <= 0 {
        str_buf_add(&sb, "0.");
        for i32 i = 0; i < -n; i++ { str_buf_add(&sb, "0"); }
        str_buf_add(&sb, s);
    } else {
        // exponential: d.ddd e(+/-)(n-1)
        u8[1] first;
        first[0] = digits[start];
        str fd;
        fd.data = &first[0];
        fd.len = 1;
        str_buf_add(&sb, fd);
        if k > 1 {
            str rest;
            rest.data = &digits[start + 1];
            rest.len = k - 1;
            str_buf_add(&sb, ".");
            str_buf_add(&sb, rest);
        }
        i32 exp = n - 1;
        str_buf_add(&sb, "e");
        if exp >= 0 { str_buf_add(&sb, "+"); } else { str_buf_add(&sb, "-"); }
        i32 ae = exp < 0 ? -exp : exp;
        string es = format("{}", ae);
        str_buf_add(&sb, es);
        free(es);
    }
    string result = string(str_buf_to_str(&sb));
    str_buf_free(&sb);
    return result;
}

// SymbolDescriptiveString (ES 20.4.3.3.1): "Symbol(desc)". Used by the
// explicit conversions (String(sym), Symbol.prototype.toString, inspect);
// implicit ToString of a symbol throws instead.
Value vm_symbol_desc(VM* vm, Value v) {
    JsSymbol* sy = value_as_symbol(v);
    str_buf sb;
    str_buf_init(&sb);
    str_buf_add(&sb, "Symbol(");
    if value_is_string(sy.desc) {
        str_buf_add(&sb, gc_string_view(value_as_string(sy.desc)));
    }
    str_buf_add(&sb, ")");
    GcString* g = gc_new_string(&vm.heap, str_buf_to_str(&sb));
    str_buf_free(&sb);
    return value_cell(&g.head);
}

// Returns a string Value; caller roots it (usually by pushing).
Value js_to_string_value(VM* vm, Value v) {
    if value_is_string(v) { return v; }
    if value_is_number(v) {
        f64 d = js_to_number(v);
        str lit;
        if num_special(d, &lit) {
            GcString* g = gc_new_string(&vm.heap, lit);
            return value_cell(&g.head);
        }
        string s = js_num_format(d);
        GcString* g = gc_new_string(&vm.heap, s);
        free(s);
        return value_cell(&g.head);
    }
    str lit = "undefined";
    bool have = false;
    if value_is_undefined(v) || value_is_hole(v) { have = true; }
    if value_is_null(v) { lit = "null"; have = true; }
    if value_is_bool(v) {
        if value_is_true(v) { lit = "true"; } else { lit = "false"; }
        have = true;
    }
    if value_is_function(v) || value_is_native(v) {
        return vm_function_source(vm, v);
    }
    if have {
        GcString* g = gc_new_string(&vm.heap, lit);
        return value_cell(&g.head);
    }
    if value_is_symbol(v) {
        // Implicit ToString of a Symbol is a TypeError; the explicit
        // conversions use vm_symbol_desc directly.
        vm_throw_error(vm, ERR_TYPE, "Cannot convert a Symbol value to a string");
        GcString* g = gc_new_string(&vm.heap, "");
        return value_cell(&g.head);
    }
    if value_is_bigint(v) {
        BigNum b = bigint_view(value_as_bigint(v));
        string s = bn_to_str(b);
        GcString* g = gc_new_string(&vm.heap, s);
        free(s);
        return value_cell(&g.head);
    }
    // object-like: ToPrimitive with the string hint (toString/valueOf),
    // then ToString the resulting primitive
    Value prim;
    if !vm_to_primitive(vm, v, HINT_STRING, &prim) {
        GcString* g = gc_new_string(&vm.heap, "");
        return value_cell(&g.head);
    }
    if value_is_string(prim) { return prim; }
    return js_to_string_value(vm, prim);
}

i32 js_str_cmp(str a, str b) {
    i32 n = a.len;
    if b.len < n { n = b.len; }
    for i32 i = 0; i < n; i++ {
        u8 ca = *(a.data + i);
        u8 cb = *(b.data + i);
        if ca != cb { return ca < cb ? -1 : 1; }
    }
    if a.len == b.len { return 0; }
    return a.len < b.len ? -1 : 1;
}

bool js_strict_eq(Value a, Value b) {
    if value_is_number(a) && value_is_number(b) {
        return js_to_number(a) == js_to_number(b);
    }
    if value_is_string(a) && value_is_string(b) {
        return str_equal(gc_string_view(value_as_string(a)), gc_string_view(value_as_string(b)));
    }
    if value_is_bigint(a) && value_is_bigint(b) {
        return bn_cmp(bigint_view(value_as_bigint(a)), bigint_view(value_as_bigint(b))) == 0;
    }
    return value_same_bits(a, b);
}

// Map/Set key equality: strict, except NaN equals NaN and +0 equals -0.
bool js_same_value_zero(Value a, Value b) {
    if value_is_number(a) && value_is_number(b) {
        f64 x = js_to_number(a);
        f64 y = js_to_number(b);
        if x != x && y != y { return true; }
        return x == y;
    }
    if value_is_string(a) && value_is_string(b) {
        return str_equal(gc_string_view(value_as_string(a)), gc_string_view(value_as_string(b)));
    }
    return value_same_bits(a, b);
}

// SameValue (Object.is): like SameValueZero but +0 and -0 differ.
bool js_same_value(Value a, Value b) {
    if value_is_number(a) && value_is_number(b) {
        f64 x = js_to_number(a);
        f64 y = js_to_number(b);
        if x != x && y != y { return true; }
        if x == 0.0 && y == 0.0 { return (1.0 / x < 0.0) == (1.0 / y < 0.0); }
        return x == y;
    }
    if value_is_string(a) && value_is_string(b) {
        return str_equal(gc_string_view(value_as_string(a)), gc_string_view(value_as_string(b)));
    }
    return value_same_bits(a, b);
}

private bool is_nullish(Value v) {
    return value_is_null(v) || value_is_undefined(v);
}

// A BigInt equals a string iff the string parses to the same integer.
private bool bigint_eq_str(GcBigInt* g, str s) {
    bool ok;
    BigNum sb = bn_from_str(s, &ok);
    if !ok { return false; }
    bool eq = bn_cmp(bigint_view(g), sb) == 0;
    bn_free(&sb);
    return eq;
}

bool js_loose_eq(Value a, Value b) {
    if is_nullish(a) || is_nullish(b) {
        return is_nullish(a) && is_nullish(b);
    }
    if value_is_number(a) && value_is_number(b) { return js_to_number(a) == js_to_number(b); }
    if value_is_string(a) && value_is_string(b) { return js_strict_eq(a, b); }
    if value_is_bool(a) { return js_loose_eq(value_int(value_is_true(a) ? 1 : 0), b); }
    if value_is_bool(b) { return js_loose_eq(a, value_int(value_is_true(b) ? 1 : 0)); }
    if value_is_number(a) && value_is_string(b) { return js_to_number(a) == js_to_number(b); }
    if value_is_string(a) && value_is_number(b) { return js_to_number(a) == js_to_number(b); }
    // BigInt: equal by mathematical value across BigInt/Number/String
    if value_is_bigint(a) && value_is_bigint(b) {
        return bn_cmp(bigint_view(value_as_bigint(a)), bigint_view(value_as_bigint(b))) == 0;
    }
    if value_is_bigint(a) && value_is_number(b) { return bn_to_f64(bigint_view(value_as_bigint(a))) == js_to_number(b); }
    if value_is_number(a) && value_is_bigint(b) { return js_to_number(a) == bn_to_f64(bigint_view(value_as_bigint(b))); }
    if value_is_bigint(a) && value_is_string(b) { return bigint_eq_str(value_as_bigint(a), gc_string_view(value_as_string(b))); }
    if value_is_string(a) && value_is_bigint(b) { return bigint_eq_str(value_as_bigint(b), gc_string_view(value_as_string(a))); }
    // object vs primitive ToPrimitive deferred; objects compare by identity
    return value_same_bits(a, b);
}

// --- exceptions --------------------------------------------------------------

void vm_throw(VM* vm, Value v) {
    vm.pending = v;
    vm.has_pending = true;
}

// A return completion, used to close a suspended generator: it unwinds like a
// throw so `finally` blocks run, but `catch` clauses decline it (see
// OP_CATCH_ENTER) and the generator boundary turns it back into a return.
void vm_throw_return(VM* vm, Value v) {
    vm.pending = v;
    vm.has_pending = true;
    vm.unwind_return = true;
}

// Builds an Error `.stack`: a "Name: message" header, then one
// "    at <fn> (<file>:<line>:<col>)" line per live frame, innermost
// first. The caller keeps any referenced object rooted. Accurate for
// user-constructed errors (the native-call site stores the caller's ip);
// a VM-internal throw's innermost line is best-effort.
Value vm_error_stack(VM* vm, str name, str msg, bool has_msg) {
    str_buf sb;
    str_buf_init(&sb);
    str_buf_add(&sb, name);
    if has_msg && msg.len > 0 {
        str_buf_add(&sb, ": ");
        str_buf_add(&sb, msg);
    }
    for i32 i = vm.fp - 1; i >= 0; i-- {
        Frame* fr = vm.frames + i;
        FnTemplate* t = fr.tmpl;
        if t == null { continue; }
        i32 off = fr.cur_ip - 1;
        if off < 0 { off = 0; }
        i32 line = 0;
        i32 col = 0;
        tmpl_pos(t, off, &line, &col);
        str_buf_add(&sb, "\n    at ");
        if t.name.len > 0 { str_buf_add(&sb, t.name); }
        else { str_buf_add(&sb, "<anonymous>"); }
        str_buf_add(&sb, " (");
        if t.src_name.len > 0 { str_buf_add(&sb, t.src_name); }
        else { str_buf_add(&sb, "<anonymous>"); }
        string ls = format(":{}:{}", line, col);
        str_buf_add(&sb, ls);
        free(ls);
        str_buf_add(&sb, ")");
    }
    GcString* g = gc_new_string(&vm.heap, str_buf_to_str(&sb));
    str_buf_free(&sb);
    return value_cell(&g.head);
}

Value vm_make_error(VM* vm, i32 kind, str msg) {
    JsObject* proto = vm.error_protos[kind];
    JsObject* e = js_new_object(&vm.heap, proto);
    vpush(vm, value_cell(&e.head));
    if proto == null {
        GcString* ns = gc_new_string(&vm.heap, vm_error_kind_name(kind));
        js_set_prop(e, vm.atom_name, value_cell(&ns.head));
    }
    // message and stack are not enumerated, so Object.keys of an error is empty
    GcString* ms = gc_new_string(&vm.heap, msg);
    props_set_desc(&e.props, vm.atom_message, value_cell(&ms.head),
        PROP_WRITABLE | PROP_CONFIGURABLE);
    Value stack = vm_error_stack(vm, vm_error_kind_name(kind), msg, msg.len > 0);
    props_set_desc(&e.props, atom_intern(&vm.atoms, "stack"), stack,
        PROP_WRITABLE | PROP_CONFIGURABLE);
    return vpop(vm);
}

void vm_throw_error(VM* vm, i32 kind, str msg) {
    vm_throw(vm, vm_make_error(vm, kind, msg));
}

// --- property helpers -----------------------------------------------------------

private Value ensure_prototype(VM* vm, Value fnv) {
    PropList* props = null;
    if value_is_function(fnv) { props = &value_as_function(fnv).props; }
    if value_is_native(fnv) { props = &value_as_native(fnv).props; }
    if props == null { return value_undefined(); }
    Value* p = props_get(props, vm.atom_prototype);
    if p != null { return *p; }
    // Only something that can be `new`ed, or a generator whose results need an
    // object to inherit from, has a .prototype at all. An arrow, a shorthand
    // method and a plain async function have none -- not an empty one.
    if value_is_function(fnv) {
        FnTemplate* ft0 = value_as_function(fnv).tmpl;
        if ft0 != null && !ft0.is_gen && (ft0.not_ctor || ft0.is_async) {
            return value_undefined();
        }
    }
    JsObject* pr = js_new_object(&vm.heap, vm.object_proto);
    // An ordinary function's .prototype carries a non-enumerable back-reference,
    // so `new Fn().constructor` resolves. A generator's .prototype has no such
    // property — it is only the object its results inherit from.
    bool gen_like = false;
    if value_is_function(fnv) {
        FnTemplate* ft = value_as_function(fnv).tmpl;
        if ft != null { gen_like = ft.is_gen || ft.is_async; }
    }
    if !gen_like {
        props_set_desc(&pr.props, atom_intern(&vm.atoms, "constructor"), fnv,
            PROP_WRITABLE | PROP_CONFIGURABLE);
    }
    if value_is_function(fnv) { props = &value_as_function(fnv).props; }
    if value_is_native(fnv) { props = &value_as_native(fnv).props; }
    // .prototype is writable but never enumerated (matches a function's
    // own prototype descriptor).
    props_set_desc(props, vm.atom_prototype, value_cell(&pr.head), PROP_WRITABLE);
    return value_cell(&pr.head);
}

// objv stays rooted by the caller; false means an error was thrown.
// --- Proxy: route fundamental operations through the handler traps ---------

// An atom as message text; the result is owned by the caller. A symbol atom
// indexes the symbol table, not the name table, so it must never reach
// atom_name -- the high bit makes the index negative and the read runs off
// the end of the table.
string vm_atom_display(VM* vm, u32 a) {
    if (a & 0x80000000) == 0 { return format("{}", atom_name(&vm.atoms, a)); }
    Value sv = vec_get(&vm.symbols, a & 0x7fffffff);
    if !value_is_symbol(sv) { return format("Symbol()"); }
    Value d = value_as_symbol(sv).desc;
    if !value_is_string(d) { return format("Symbol()"); }
    return format("Symbol({})", gc_string_view(value_as_string(d)));
}

// A property-key atom back to its key Value: a Symbol for a symbol atom
// (high bit set), else a string.
Value atom_to_key(VM* vm, u32 a) {
    if (a & 0x80000000) != 0 {
        return vec_get(&vm.symbols, a & 0x7fffffff);
    }
    GcString* g = gc_new_string(&vm.heap, atom_name(&vm.atoms, a));
    return value_cell(&g.head);
}

// Look up a named trap on a proxy handler. Returns 1 with *out set (a
// callable trap), 0 (absent — the caller performs the default on the
// target), or -1 (present but not callable — a TypeError was thrown).
// True (and throws) if the proxy has been revoked.
private bool proxy_revoked(VM* vm, JsProxy* p) {
    if (p.obj_flags & OBJF_PROXY_REVOKED) != 0 {
        vm_throw_error(vm, ERR_TYPE, "Cannot perform operation on a proxy that has been revoked");
        return true;
    }
    return false;
}

private i32 proxy_trap(VM* vm, JsProxy* p, str name, Value* out) {
    if proxy_revoked(vm, p) { return 0 - 1; }
    Value t;
    if !vm_get_prop_value(vm, p.handler, atom_intern(&vm.atoms, name), &t) { return 0; }
    if value_is_undefined(t) || value_is_null(t) { return 0; }
    if !value_is_callable(t) {
        vm_throw_error(vm, ERR_TYPE, "proxy handler trap is not a function");
        return 0 - 1;
    }
    *out = t;
    return 1;
}

private bool proxy_get(VM* vm, JsProxy* p, u32 a, Value receiver, Value* out) {
    Value trap;
    i32 tr = proxy_trap(vm, p, "get", &trap);
    if tr < 0 { *out = value_undefined(); return false; }
    if tr == 0 { return get_prop_atom(vm, p.target, a, out); }
    i32 rm = gc_root_mark(&vm.heap);
    Value key = atom_to_key(vm, a);
    gc_root(&vm.heap, key);
    noinit Value[3] cargs;
    cargs[0] = p.target;
    cargs[1] = key;
    cargs[2] = receiver;
    *out = vm_call_value(vm, trap, p.handler, &cargs[0], 3);
    gc_root_reset(&vm.heap, rm);
    return !vm.has_pending;
}

private bool proxy_set(VM* vm, JsProxy* p, u32 a, Value v, Value receiver) {
    Value trap;
    i32 tr = proxy_trap(vm, p, "set", &trap);
    if tr < 0 { return false; }
    if tr == 0 { return set_prop_atom(vm, p.target, a, v); }
    i32 rm = gc_root_mark(&vm.heap);
    Value key = atom_to_key(vm, a);
    gc_root(&vm.heap, key);
    noinit Value[4] cargs;
    cargs[0] = p.target;
    cargs[1] = key;
    cargs[2] = v;
    cargs[3] = receiver;
    ignore vm_call_value(vm, trap, p.handler, &cargs[0], 4);
    gc_root_reset(&vm.heap, rm);
    return !vm.has_pending;
}

bool proxy_has(VM* vm, JsProxy* p, u32 a) {
    Value trap;
    i32 tr = proxy_trap(vm, p, "has", &trap);
    if tr < 0 { return false; }
    if tr == 0 {
        if value_is_object(p.target) { return js_has_prop(value_as_object(p.target), a); }
        return false;
    }
    i32 rm = gc_root_mark(&vm.heap);
    Value key = atom_to_key(vm, a);
    gc_root(&vm.heap, key);
    noinit Value[2] cargs;
    cargs[0] = p.target;
    cargs[1] = key;
    Value r = vm_call_value(vm, trap, p.handler, &cargs[0], 2);
    gc_root_reset(&vm.heap, rm);
    return js_truthy(r);
}

bool proxy_delete(VM* vm, JsProxy* p, u32 a) {
    Value trap;
    i32 tr = proxy_trap(vm, p, "deleteProperty", &trap);
    if tr < 0 { return false; }
    if tr == 0 {
        if value_is_object(p.target) { return js_delete_prop(value_as_object(p.target), a); }
        return true;
    }
    i32 rm = gc_root_mark(&vm.heap);
    Value key = atom_to_key(vm, a);
    gc_root(&vm.heap, key);
    noinit Value[2] cargs;
    cargs[0] = p.target;
    cargs[1] = key;
    Value r = vm_call_value(vm, trap, p.handler, &cargs[0], 2);
    gc_root_reset(&vm.heap, rm);
    return js_truthy(r);
}

// The named handler trap if present and callable, else undefined (no throw).
// For builtins implementing the descriptor/defineProperty/ownKeys traps.
Value proxy_trap_fn(VM* vm, JsProxy* p, str name) {
    if proxy_revoked(vm, p) { return value_undefined(); }
    Value t;
    if !vm_get_prop_value(vm, p.handler, atom_intern(&vm.atoms, name), &t) { return value_undefined(); }
    if value_is_undefined(t) || value_is_null(t) { return value_undefined(); }
    if !value_is_callable(t) { return value_undefined(); }
    return t;
}

// Build a JS array from raw call arguments (for the apply/construct traps).
private Value args_to_array(VM* vm, Value* argstart, i32 argc) {
    JsObject* arr = js_new_array(&vm.heap, vm.array_proto);
    for i32 i = 0; i < argc; i++ { js_array_set(arr, i, *(argstart + i)); }
    return value_cell(&arr.head);
}

// Calling a callable-target proxy: the apply trap (target, thisArg, argsArray),
// or a plain call of the target when absent.
Value proxy_apply(VM* vm, JsProxy* p, Value thisv, Value* argstart, i32 argc) {
    Value trap;
    i32 tr = proxy_trap(vm, p, "apply", &trap);
    if tr < 0 { return value_undefined(); }
    if tr == 0 { return vm_call_value(vm, p.target, thisv, argstart, argc); }
    i32 rm = gc_root_mark(&vm.heap);
    Value arr = args_to_array(vm, argstart, argc);
    gc_root(&vm.heap, arr);
    noinit Value[3] ca;
    ca[0] = p.target;
    ca[1] = thisv;
    ca[2] = arr;
    Value r = vm_call_value(vm, trap, p.handler, &ca[0], 3);
    gc_root_reset(&vm.heap, rm);
    return r;
}

// `new` on a callable-target proxy: the construct trap (target, argsArray,
// newTarget). A default construct (no trap) needs a C-level `new` the VM
// doesn't expose, so it is unsupported here.
Value proxy_construct(VM* vm, JsProxy* p, Value* argstart, i32 argc, Value new_target) {
    Value trap;
    i32 tr = proxy_trap(vm, p, "construct", &trap);
    if tr < 0 { return value_undefined(); }
    if tr == 0 {
        // no trap: construct the target, as `new` on it directly would
        if !value_is_callable(p.target) {
            vm_throw_error(vm, ERR_TYPE, "proxy target is not a constructor");
            return value_undefined();
        }
        i32 crm = gc_root_mark(&vm.heap);
        JsObject* cproto = vm.object_proto;
        Value cpv;
        if vm_get_prop_value(vm, p.target, vm.atom_prototype, &cpv) && value_is_object(cpv) {
            cproto = value_as_object(cpv);
        }
        JsObject* cinst = js_new_object(&vm.heap, cproto);
        Value cinstv = value_cell(&cinst.head);
        gc_root(&vm.heap, cinstv);
        vm.pending_new_target = new_target;
        Value cres = vm_call_value(vm, p.target, cinstv, argstart, argc);
        vm.pending_new_target = value_undefined();
        gc_root_reset(&vm.heap, crm);
        if vm.has_pending { return value_undefined(); }
        // a constructor returning an object replaces the fresh instance
        if value_is_reference(cres) { return cres; }
        return cinstv;
    }
    i32 rm = gc_root_mark(&vm.heap);
    Value arr = args_to_array(vm, argstart, argc);
    gc_root(&vm.heap, arr);
    noinit Value[3] ca;
    ca[0] = p.target;
    ca[1] = arr;
    ca[2] = new_target;
    Value r = vm_call_value(vm, trap, p.handler, &ca[0], 3);
    gc_root_reset(&vm.heap, rm);
    return r;
}

// ownKeys: the handler trap result (an array of keys), or the target's own
// keys when absent. The result may contain string and symbol keys.
JsObject* proxy_own_keys(VM* vm, JsProxy* p) {
    Value trap;
    i32 tr = proxy_trap(vm, p, "ownKeys", &trap);
    if tr < 0 { return js_new_array(&vm.heap, vm.array_proto); }
    if tr == 0 { return vm_own_keys(vm, p.target); }
    noinit Value[1] cargs;
    cargs[0] = p.target;
    Value r = vm_call_value(vm, trap, p.handler, &cargs[0], 1);
    if vm.has_pending { return js_new_array(&vm.heap, vm.array_proto); }
    if value_is_array(r) { return value_as_object(r); }
    return js_new_array(&vm.heap, vm.array_proto);
}

private bool get_prop_atom(VM* vm, Value objv, u32 a, Value* out) {
    *out = value_undefined();
    if value_is_object(objv) {
        JsObject* o = value_as_object(objv);
        if (o.obj_flags & OBJF_PROXY) != 0 {
            return proxy_get(vm, cast(JsProxy*, o), a, objv, out);
        }
        if (o.obj_flags & OBJF_GLOBAL) != 0 {
            // read the binding itself, so a global declared after this object
            // was built is still visible through it
            Value* g = vm_global_hidden(vm, a) ? null : intmap_get<Value>(&vm.globals, a);
            if g != null {
                // an accessor is handed back as-is; vm_get_prop_value resolves
                // it, which is also what makes a lazy global work here
                *out = *g;
                return true;
            }
            // not a binding: fall through for Object.prototype and anything
            // defined directly on the object
        }
        if (o.obj_flags & OBJF_ARRAY) != 0 {
            if a == vm.atom_length {
                *out = value_int(o.elen);
                return true;
            }
            // a string-numeric key (e.g. arr["1"]) reads the element part
            i32 idx = ta_atom_index(vm, a);
            if idx >= 0 && idx < o.elen {
                *out = js_array_get(o, idx);
                return true;
            }
        }
        if (o.obj_flags & OBJF_TYPEDARRAY) != 0 {
            i32 idx = ta_atom_index(vm, a);
            if idx >= 0 {
                *out = vm_ta_get(vm, o, idx);   // undefined when out of range
                return true;
            }
        }
        ignore js_get_prop(o, a, out);
        return true;
    }
    if value_is_function(objv) || value_is_native(objv) {
        if a == vm.atom_prototype {
            *out = ensure_prototype(vm, objv);
            return true;
        }
        PropList* props = null;
        if value_is_function(objv) { props = &value_as_function(objv).props; }
        if value_is_native(objv) { props = &value_as_native(objv).props; }
        Value* p = props_get(props, a);
        if p != null {
            *out = *p;
            return true;
        }
        // synthesize name/length when not set explicitly
        if a == vm.atom_name {
            str nm = "";
            if value_is_native(objv) {
                nm = value_as_native(objv).name;
            } else {
                FnTemplate* ft = value_as_function(objv).tmpl;
                if ft != null { nm = ft.name; }
            }
            GcString* g = gc_new_string(&vm.heap, nm);
            *out = value_cell(&g.head);
            return true;
        }
        if a == vm.atom_length {
            i32 arity = 0;
            if value_is_function(objv) {
                FnTemplate* ft = value_as_function(objv).tmpl;
                if ft != null { arity = ft.arity; }
            }
            *out = value_int(arity);
            return true;
        }
        // [[Prototype]] chain: an explicitly set fproto (a parent ctor, or a
        // plain object via Object.setPrototypeOf), otherwise Function.prototype.
        if value_is_function(objv) {
            Value fp = value_as_function(objv).fproto;
            if value_is_function(fp) || value_is_native(fp) {
                return get_prop_atom(vm, fp, a, out);
            }
            if value_is_object(fp) {
                ignore js_get_prop(value_as_object(fp), a, out);
                return true;
            }
            if value_is_null(fp) {
                return true;   // explicit null [[Prototype]]: nothing inherited
            }
        }
        if vm.function_proto != null { ignore js_get_prop(vm.function_proto, a, out); }
        return true;
    }
    if value_is_string(objv) {
        if a == vm.atom_length {
            *out = value_int(value_as_string(objv).u16len);
            return true;
        }
        if vm.string_proto != null { ignore js_get_prop(vm.string_proto, a, out); }
        return true;
    }
    if is_nullish(objv) {
        str which = value_is_null(objv) ? "null" : "undefined";
        string kn = vm_atom_display(vm, a);
        string msg = format("Cannot read properties of {} (reading '{}')", which, kn);
        vm_throw_error(vm, ERR_TYPE, msg);
        free(msg);
        free(kn);
        return false;
    }
    if value_is_number(objv) {
        if vm.number_proto != null { ignore js_get_prop(vm.number_proto, a, out); }
        return true;
    }
    if value_is_bool(objv) {
        if vm.boolean_proto != null { ignore js_get_prop(vm.boolean_proto, a, out); }
        return true;
    }
    if value_is_symbol(objv) {
        if vm.symbol_proto != null { ignore js_get_prop(vm.symbol_proto, a, out); }
        return true;
    }
    if value_is_bigint(objv) {
        if vm.bigint_proto != null { ignore js_get_prop(vm.bigint_proto, a, out); }
        return true;
    }
    if value_is_generator(objv) {
        JsObject* gp = value_as_generator(objv).is_async ? vm.async_generator_proto : vm.generator_proto;
        if gp != null { ignore js_get_prop(gp, a, out); }
        return true;
    }
    if value_is_map(objv) {
        JsObject* mproto = value_as_map(objv).proto;
        if mproto != null { ignore js_get_prop(mproto, a, out); }
        return true;
    }
    return true;
}

// HasProperty for a callable receiver (function/native): own props, the
// synthesized name/length/prototype, then the [[Prototype]] chain — a parent
// ctor, a plain object set via Object.setPrototypeOf, or Function.prototype.
bool fn_has_prop(VM* vm, Value objv, u32 a) {
    PropList* props = value_is_function(objv)
        ? &value_as_function(objv).props : &value_as_native(objv).props;
    if props_entry(props, a) != null { return true; }
    if a == vm.atom_name || a == vm.atom_length || a == vm.atom_prototype { return true; }
    if value_is_function(objv) {
        Value fp = value_as_function(objv).fproto;
        if value_is_function(fp) || value_is_native(fp) { return fn_has_prop(vm, fp, a); }
        if value_is_object(fp) { return js_has_prop(value_as_object(fp), a); }
        if value_is_null(fp) { return false; }
    }
    if vm.function_proto != null { return js_has_prop(vm.function_proto, a); }
    return false;
}

// The accessor for `a` on a function/native receiver: own properties first,
// then the [[Prototype]] chain (a parent constructor or a plain object), the
// same walk fn_has_prop does. null when the property is absent or plain data.
private JsAccessor* fn_find_accessor(Value objv, u32 a) {
    Value cur = objv;
    while true {
        if value_is_object(cur) {
            JsObject* o = value_as_object(cur);
            while o != null {
                Prop* pe = props_entry(&o.props, a);
                if pe != null {
                    if value_is_accessor(pe.val) { return value_as_accessor(pe.val); }
                    return null;
                }
                o = o.proto;
            }
            return null;
        }
        PropList* props = null;
        if value_is_function(cur) { props = &value_as_function(cur).props; }
        else if value_is_native(cur) { props = &value_as_native(cur).props; }
        else { return null; }
        Prop* pe = props_entry(props, a);
        if pe != null {
            if value_is_accessor(pe.val) { return value_as_accessor(pe.val); }
            return null;
        }
        if !value_is_function(cur) { return null; }
        cur = value_as_function(cur).fproto;
    }
}

// Resolves accessor properties through their getter; false = threw.
bool vm_get_prop_value(VM* vm, Value objv, u32 a, Value* out) {
    if !get_prop_atom(vm, objv, a, out) { return false; }
    if value_is_accessor(*out) {
        JsAccessor* ac = value_as_accessor(*out);
        if !value_is_callable(ac.get) {
            *out = value_undefined();
            return true;
        }
        Value dummy = value_undefined();
        *out = vm_call_value(vm, ac.get, objv, &dummy, 0);
        return !vm.has_pending;
    }
    return true;
}

// Public property set through the full path (proxy set trap, array length,
// typed arrays, accessors). Used by Reflect.set and similar.
bool vm_set_prop_value(VM* vm, Value objv, u32 a, Value v) {
    return set_prop_atom(vm, objv, a, v);
}

// Public delete through the full path, so a proxy's deleteProperty trap
// fires. Used by the generic (array-like receiver) Array methods.
bool vm_delete_prop_value(VM* vm, Value objv, u32 a) {
    if value_is_object(objv) {
        JsObject* o = value_as_object(objv);
        if (o.obj_flags & OBJF_PROXY) != 0 { return proxy_delete(vm, cast(JsProxy*, o), a); }
        return js_delete_prop(o, a);
    }
    PropList* props = value_props(objv);
    if props != null { return props_remove(props, a); }
    return true;
}

private bool set_prop_atom(VM* vm, Value objv, u32 a, Value v) {
    if value_is_object(objv) {
        JsObject* o = value_as_object(objv);
        if (o.obj_flags & OBJF_PROXY) != 0 {
            return proxy_set(vm, cast(JsProxy*, o), a, v, objv);
        }
        if (o.obj_flags & OBJF_GLOBAL) != 0 {
            // writing a property of the global object creates or updates the
            // binding a bare name resolves to
            intmap_set<Value>(&vm.globals, a, v);
            return true;
        }
        if (o.obj_flags & OBJF_ARRAY) != 0 {
            if a == vm.atom_length {
                f64 n = js_to_number(v);
                i32 ni = cast(i32, n);
                if cast(f64, ni) == n && ni >= 0 {
                    js_array_set_length(o, ni);
                    return true;
                }
                vm_throw_error(vm, ERR_RANGE, "invalid array length");
                return false;
            }
            // a string-numeric key (e.g. arr["1"] = x) writes the element part
            i32 idx = ta_atom_index(vm, a);
            if idx >= 0 {
                if (o.obj_flags & OBJF_FROZEN) != 0 {
                    vm_throw_error(vm, ERR_TYPE, "cannot assign to read-only property of a frozen array");
                    return false;
                }
                if idx >= o.elen && (o.obj_flags & OBJF_NONEXT) != 0 {
                    vm_throw_error(vm, ERR_TYPE, "cannot add property to a non-extensible array");
                    return false;
                }
                js_array_set(o, idx, v);
                return true;
            }
        }
        if (o.obj_flags & OBJF_TYPEDARRAY) != 0 {
            i32 idx = ta_atom_index(vm, a);
            if idx >= 0 {
                vm_ta_set(vm, o, idx, v);   // out-of-range writes are ignored
                return true;
            }
        }
        // a setter anywhere on the chain intercepts the write
        JsObject* cur = o;
        while cur != null {
            Prop* pe = props_entry(&cur.props, a);
            if pe != null {
                if value_is_accessor(pe.val) {
                    JsAccessor* ac = value_as_accessor(pe.val);
                    if value_is_callable(ac.set) {
                        Value[1] sa = { v };
                        ignore vm_call_value(vm, ac.set, objv, &sa[0], 1);
                        return !vm.has_pending;
                    }
                    // strict mode throughout, so a failed write is an error
                    // rather than the sloppy-mode silent no-op
                    vm_throw_error(vm, ERR_TYPE, "cannot set property which has only a getter");
                    return false;
                }
                if cur == o {
                    if (pe.flags & PROP_WRITABLE) == 0 {
                        vm_throw_error(vm, ERR_TYPE, "cannot assign to read-only property");
                        return false;
                    }
                    pe.val = v;
                    return true;
                }
                // an inherited non-writable data property blocks the write
                if (pe.flags & PROP_WRITABLE) == 0 {
                    vm_throw_error(vm, ERR_TYPE, "cannot assign to read-only property");
                    return false;
                }
                break;
            }
            cur = cur.proto;
        }
        // a fresh property cannot be added to a non-extensible object
        if (o.obj_flags & OBJF_NONEXT) != 0 {
            vm_throw_error(vm, ERR_TYPE, "cannot add property to a non-extensible object");
            return false;
        }
        js_set_prop(o, a, v);
        return true;
    }
    if value_is_function(objv) || value_is_native(objv) {
        // a setter on the function or its [[Prototype]] intercepts the write,
        // as it does for ordinary objects (static accessors live here)
        JsAccessor* ac = fn_find_accessor(objv, a);
        if ac != null {
            if value_is_callable(ac.set) {
                Value[1] sa = { v };
                ignore vm_call_value(vm, ac.set, objv, &sa[0], 1);
                return !vm.has_pending;
            }
            vm_throw_error(vm, ERR_TYPE, "cannot set property which has only a getter");
            return false;
        }
        if value_is_function(objv) { props_set(&value_as_function(objv).props, a, v); }
        else { props_set(&value_as_native(objv).props, a, v); }
        return true;
    }
    if is_nullish(objv) {
        vm_throw_error(vm, ERR_TYPE, "cannot set properties of null or undefined");
        return false;
    }
    return true;
}

private i32 val_to_index(Value v) {
    if value_is_int(v) {
        i32 i = value_as_int(v);
        return i >= 0 ? i : -1;
    }
    if value_is_double(v) {
        f64 d = value_as_f64(v);
        i32 i = cast(i32, d);
        if cast(f64, i) == d && i >= 0 { return i; }
    }
    return -1;
}

// --- TypedArray element access ----------------------------------------------
// Element kinds: 0 Int8, 1 Uint8, 2 Uint8Clamped, 3 Int16, 4 Uint16,
// 5 Int32, 6 Uint32, 7 Float32, 8 Float64. Storage is platform-endian
// (little-endian), so reads/writes go through memcpy of the native width.

i32 ta_elem_size(i32 kind) {
    if kind <= 2 { return 1; }
    if kind <= 4 { return 2; }
    if kind == 8 { return 8; }
    return 4;
}

// Parses a property atom as a canonical array index ("0" or a no-leading-
// zero decimal) or returns -1. Used to route typed-array index properties
// (t["0"], Object.values, spread) through the element accessors.
i32 ta_atom_index(VM* vm, u32 a) {
    if (a & 0x80000000) != 0 { return -1; }   // symbol keys are never indices
    str s = atom_name(&vm.atoms, a);
    if s.len == 0 { return -1; }
    if *(s.data) == '0' { return s.len == 1 ? 0 : -1; }
    i64 v = 0;
    for i32 i = 0; i < s.len; i++ {
        u8 c = *(s.data + i);
        if c < '0' || c > '9' { return -1; }
        v = v * 10 + cast(i64, c - '0');
        if v > 2147483647 { return -1; }
    }
    return cast(i32, v);
}

str ta_kind_name(i32 kind) {
    if kind == 0 { return "Int8Array"; }
    if kind == 1 { return "Uint8Array"; }
    if kind == 2 { return "Uint8ClampedArray"; }
    if kind == 3 { return "Int16Array"; }
    if kind == 4 { return "Uint16Array"; }
    if kind == 5 { return "Int32Array"; }
    if kind == 6 { return "Uint32Array"; }
    if kind == 7 { return "Float32Array"; }
    return "Float64Array";
}

Value ta_read(u8* p, i32 kind) {
    if kind == 0 {
        i32 v = cast(i32, *p);
        if v >= 128 { v -= 256; }
        return value_int(v);
    }
    if kind == 1 || kind == 2 { return value_int(cast(i32, *p)); }
    if kind == 3 {
        u16 w;
        memcpy(cast(u8*, &w), p, cast(i64, 2));
        i32 v = cast(i32, w);
        if v >= 32768 { v -= 65536; }
        return value_int(v);
    }
    if kind == 4 { u16 w; memcpy(cast(u8*, &w), p, cast(i64, 2)); return value_int(cast(i32, w)); }
    if kind == 5 { i32 v; memcpy(cast(u8*, &v), p, cast(i64, 4)); return value_int(v); }
    if kind == 6 { u32 v; memcpy(cast(u8*, &v), p, cast(i64, 4)); return value_number(cast(f64, v)); }
    if kind == 7 { f32 f; memcpy(cast(u8*, &f), p, cast(i64, 4)); return value_number(cast(f64, f)); }
    f64 d;
    memcpy(cast(u8*, &d), p, cast(i64, 8));
    return value_number(d);
}

void ta_write(u8* p, i32 kind, f64 num) {
    if kind == 8 { memcpy(p, cast(u8*, &num), cast(i64, 8)); return; }
    if kind == 7 { f32 f = cast(f32, num); memcpy(p, cast(u8*, &f), cast(i64, 4)); return; }
    if kind == 2 {   // Uint8Clamped: ties round to the even value
        i32 c;
        if num != num || num <= 0.0 { c = 0; }
        else if num >= 255.0 { c = 255; }
        else {
            f64 fl = floor(num);
            f64 frac = num - fl;
            c = cast(i32, fl);
            if frac > 0.5 { c = c + 1; }
            else if frac == 0.5 && (c & 1) != 0 { c = c + 1; }
        }
        *p = cast(u8, c);
        return;
    }
    i64 iv = 0;
    f64 inf = 1.0e308 * 10.0;
    if num == num && num != inf && num != 0.0 - inf { iv = cast(i64, num); }
    u32 u = cast(u32, iv);
    if kind == 0 || kind == 1 { *p = cast(u8, u & 0xFF); return; }
    if kind == 3 || kind == 4 { u16 w = cast(u16, u & 0xFFFF); memcpy(p, cast(u8*, &w), cast(i64, 2)); return; }
    memcpy(p, cast(u8*, &u), cast(i64, 4));
}

// True for a TypedArray view; the element get/set below read its bytes.
bool vm_is_typed_array(Value v) {
    return value_is_object(v) && (value_as_object(v).obj_flags & OBJF_TYPEDARRAY) != 0;
}

private i32 ta_prop_int(VM* vm, JsObject* o, u32 atom) {
    Value* p = props_get(&o.props, atom);
    if p == null { return 0; }
    return value_as_int(*p);
}

Value vm_ta_get(VM* vm, JsObject* o, i32 idx) {
    i32 len = ta_prop_int(vm, o, vm.atom_ta_len);
    if idx < 0 || idx >= len { return value_undefined(); }
    if o.elen < 1 { return value_undefined(); }
    GcBytes* gb = value_as_bytes(*(o.elems));
    i32 off = ta_prop_int(vm, o, vm.atom_ta_off);
    i32 kind = ta_prop_int(vm, o, vm.atom_ta_kind);
    return ta_read(gb_data(gb) + off + idx * ta_elem_size(kind), kind);
}

void vm_ta_set(VM* vm, JsObject* o, i32 idx, Value v) {
    i32 len = ta_prop_int(vm, o, vm.atom_ta_len);
    if idx < 0 || idx >= len { return; }
    if o.elen < 1 { return; }
    GcBytes* gb = value_as_bytes(*(o.elems));
    i32 off = ta_prop_int(vm, o, vm.atom_ta_off);
    i32 kind = ta_prop_int(vm, o, vm.atom_ta_kind);
    f64 num = js_to_number(v);
    ta_write(gb_data(gb) + off + idx * ta_elem_size(kind), kind, num);
}

// Key value → property atom; key must stay rooted by the caller.
// Symbols map to their reserved id.
private u32 key_to_atom(VM* vm, Value key) {
    if value_is_symbol(key) { return value_as_symbol(key).id; }
    Value s = js_to_string_value(vm, key);
    vpush(vm, s);
    u32 a = atom_intern(&vm.atoms, gc_string_view(value_as_string(s)));
    vm.sp--;
    return a;
}

// Installs `fnv` as the getter or setter of `a` on `objv`, reusing an existing
// accessor there so a get/set pair defined separately lands on one property.
private void def_accessor(VM* vm, Value objv, u32 a, Value fnv, bool is_getter, bool enumer) {
    PropList* props = null;
    if value_is_object(objv) { props = &value_as_object(objv).props; }
    else if value_is_function(objv) { props = &value_as_function(objv).props; }
    else if value_is_native(objv) { props = &value_as_native(objv).props; }
    if props == null { return; }
    Value* ex = props_get(props, a);
    JsAccessor* ac = null;
    if ex != null && value_is_accessor(*ex) {
        ac = value_as_accessor(*ex);
    } else {
        ac = js_new_accessor(&vm.heap);
        // class accessors are non-enumerable; object-literal ones enumerable
        u8 attrs = PROP_CONFIGURABLE;
        if enumer { attrs = PROP_CONFIGURABLE | PROP_ENUMERABLE; }
        props_set_desc(props, a, value_cell(&ac.head), attrs);
    }
    if is_getter { ac.get = fnv; } else { ac.set = fnv; }
}

// True when the atom spells a canonical array index ("0", "1", ...
// "4294967294"): decimal digits, no sign, no leading zero, in range.
bool vm_key_array_index(VM* vm, u32 key, u32* out) {
    if (key & 0x80000000) != 0 { return false; }
    str nm = atom_name(&vm.atoms, key);
    if nm.len == 0 || nm.len > 10 { return false; }
    if *(nm.data) == '0' && nm.len > 1 { return false; }
    u64 v = 0;
    for i32 i = 0; i < nm.len; i++ {
        u8 c = *(nm.data + i);
        if c < cast(u8, '0') || c > cast(u8, '9') { return false; }
        v = v * 10 + cast(u64, c - cast(u8, '0'));
    }
    if v > 4294967294 { return false; }
    *out = cast(u32, v);
    return true;
}

// Own property order per spec: array-index keys in ascending numeric order,
// then the string keys in insertion order, then the symbol keys in insertion
// order. Reorders the list in place so the enumeration sites can keep their
// plain loops. The scan is a no-op unless the object actually holds keys out
// of order, which is the common case.
void vm_props_order(VM* vm, PropList* p) {
    i32 nidx = 0;
    bool ordered = true;
    bool seen_other = false;
    bool seen_sym = false;
    u32 prev = 0;
    for i32 i = 0; i < p.len; i++ {
        u32 key = (p.items + i).key;
        u32 iv = 0;
        if (key & 0x80000000) != 0 {
            seen_sym = true;
        } else if vm_key_array_index(vm, key, &iv) {
            if seen_other || seen_sym || (nidx > 0 && iv < prev) { ordered = false; }
            prev = iv;
            nidx++;
        } else {
            if seen_sym { ordered = false; }
            seen_other = true;
        }
    }
    if ordered { return; }

    Prop* out = alloc<Prop>(p.len);
    i32 n = 0;
    // index keys first, kept sorted as they are inserted
    for i32 i = 0; i < p.len; i++ {
        u32 iv = 0;
        if ((p.items + i).key & 0x80000000) != 0 { continue; }
        if !vm_key_array_index(vm, (p.items + i).key, &iv) { continue; }
        i32 at = n;
        while at > 0 {
            u32 pv = 0;
            ignore vm_key_array_index(vm, (out + at - 1).key, &pv);
            if pv <= iv { break; }
            *(out + at) = *(out + at - 1);
            at--;
        }
        *(out + at) = *(p.items + i);
        n++;
    }
    // then the string keys, in insertion order
    for i32 i = 0; i < p.len; i++ {
        u32 iv = 0;
        if ((p.items + i).key & 0x80000000) != 0 { continue; }
        if vm_key_array_index(vm, (p.items + i).key, &iv) { continue; }
        *(out + n) = *(p.items + i);
        n++;
    }
    // and the symbol keys last
    for i32 i = 0; i < p.len; i++ {
        if ((p.items + i).key & 0x80000000) == 0 { continue; }
        *(out + n) = *(p.items + i);
        n++;
    }
    for i32 i = 0; i < p.len; i++ { *(p.items + i) = *(out + i); }
    free(out);
    props_reindex(p);
}

// Symbol keys and %-hidden atoms stay out of enumeration.
bool vm_enumerable_key(VM* vm, u32 key) {
    if (key & 0x80000000) != 0 { return false; }
    str nm = atom_name(&vm.atoms, key);
    if nm.len > 0 && *(nm.data) == '%' { return false; }
    return true;
}

// A property shows up in enumeration when its key is visible and the
// enumerable attribute is set (Object.defineProperty can clear it).
// Function.prototype.toString: the text a function was written as. A native,
// a bound function and anything else without a recorded span report the form
// node uses for a builtin.
Value vm_function_source(VM* vm, Value v) {
    FnTemplate* t = null;
    str nm;
    nm.data = null;
    nm.len = 0;
    if value_is_function(v) {
        t = value_as_function(v).tmpl;
        if t != null { nm = t.name; }
    } else if value_is_native(v) {
        nm = value_as_native(v).name;
    }
    if t != null && t.src_end > t.src_start && t.src_end <= t.src_text.len {
        str s;
        s.data = t.src_text.data + t.src_start;
        s.len = t.src_end - t.src_start;
        GcString* g = gc_new_string(&vm.heap, s);
        return value_cell(&g.head);
    }
    str_buf sb;
    str_buf_init(&sb);
    str_buf_add(&sb, "function ");
    str_buf_add(&sb, nm);
    str_buf_add(&sb, "() { [native code] }");
    GcString* g = gc_new_string(&vm.heap, str_buf_to_str(&sb));
    str_buf_free(&sb);
    return value_cell(&g.head);
}

bool prop_enumerable(VM* vm, Prop* pr) {
    if (pr.flags & PROP_ENUMERABLE) == 0 { return false; }
    return vm_enumerable_key(vm, pr.key);
}

// Object.assign and object spread copy own enumerable properties *including*
// symbol-keyed ones, unlike Object.keys/for-in. Only the internal %-hidden
// atoms stay out.
bool prop_copyable(VM* vm, Prop* pr) {
    if (pr.flags & PROP_ENUMERABLE) == 0 { return false; }
    if (pr.key & 0x80000000) != 0 { return true; }
    str nm = atom_name(&vm.atoms, pr.key);
    if nm.len > 0 && *(nm.data) == '%' { return false; }
    return true;
}

// --- globals ------------------------------------------------------------------------

void vm_set_main_module(VM* vm, JsObject* m) { vm.main_module = m; }

// A binding the global object does not expose. See hidden_globals.
void vm_hide_global(VM* vm, str name) {
    if vm.n_hidden_globals >= 4 { return; }
    vm.hidden_globals[vm.n_hidden_globals] = atom_intern(&vm.atoms, name);
    vm.n_hidden_globals++;
}

bool vm_global_hidden(VM* vm, u32 a) {
    for i32 i = 0; i < vm.n_hidden_globals; i++ {
        if vm.hidden_globals[i] == a { return true; }
    }
    return false;
}

// Whether a global binding of this atom exists. The global object needs to
// answer for its bindings, which do not live in its property table.
bool vm_global_exists(VM* vm, u32 a) {
    if vm_global_hidden(vm, a) { return false; }
    return intmap_get<Value>(&vm.globals, a) != null;
}

// Every global binding name, for enumerating the global object.
JsObject* vm_global_names(VM* vm) {
    JsObject* arr = js_new_array(&vm.heap, vm.array_proto);
    vpush(vm, value_cell(&arr.head));
    i32 n = 0;
    for i32 i = 0; i < vm.globals.cap; i++ {
        IntSlot<Value>* sl = vm.globals.slots + i;
        if sl.state != SLOT_USED { continue; }
        if (sl.key & 0x80000000) != 0 { continue; }   // symbol-keyed
        if vm_global_hidden(vm, sl.key) { continue; }
        GcString* g = gc_new_string(&vm.heap, atom_name(&vm.atoms, sl.key));
        js_array_set(arr, n, value_cell(&g.head));
        n++;
    }
    vm.sp--;
    return arr;
}

void vm_set_global(VM* vm, str name, Value v) {
    u32 a = atom_intern(&vm.atoms, name);
    intmap_set<Value>(&vm.globals, a, v);
}

// A global whose value is produced on first read. Stored as an accessor, which
// the global read path resolves, so a binding backed by an internal module
// costs nothing for scripts that never mention it. Because globalThis mirrors
// the globals table by descriptor, the same accessor also serves
// globalThis.<name> when installed before that snapshot.
void vm_set_lazy_global(VM* vm, str name, NativeFn getter) {
    // the accessor is rooted before the getter is allocated: until it lands in
    // the globals table nothing else references it
    i32 rm = gc_root_mark(&vm.heap);
    JsAccessor* ac = js_new_accessor(&vm.heap);
    Value acv = value_cell(&ac.head);
    gc_root(&vm.heap, acv);
    ac.get = vm_make_native(vm, getter, name);
    vm_set_global(vm, name, acv);
    gc_root_reset(&vm.heap, rm);
}

// Mirrors an existing global onto the globalThis object. That object is a
// snapshot taken while the built-ins are installed, so globals added later
// (the entry-point ones: fetch and its data types) have to be published
// explicitly to show up as properties. Node makes `fetch` enumerable but its
// data types not, hence the flag.
void vm_mirror_global(VM* vm, str name, bool enumerable) {
    Value* gt = intmap_get<Value>(&vm.globals, atom_intern(&vm.atoms, "globalThis"));
    if gt == null || !value_is_object(*gt) { return; }
    u32 a = atom_intern(&vm.atoms, name);
    Value* v = intmap_get<Value>(&vm.globals, a);
    if v == null { return; }
    u8 attrs = PROP_WRITABLE | PROP_CONFIGURABLE;
    if enumerable { attrs = attrs | PROP_ENUMERABLE; }
    props_set_desc(&value_as_object(*gt).props, a, *v, attrs);
}

Value vm_make_native(VM* vm, NativeFn f, str name) {
    JsNative* n = js_new_native(&vm.heap, f, name);
    return value_cell(&n.head);
}

// A primitive value is anything that is not an object-like reference.
private bool value_is_primitive(Value v) {
    if !value_is_cell(v) { return true; }
    return value_is_string(v) || value_is_symbol(v) || value_is_bigint(v);
}

// ToPrimitive (ES 7.1.1): if the object has a Symbol.toPrimitive method,
// call it with the hint; otherwise invoke valueOf/toString ordered by
// hint and return the first primitive. v stays rooted by the caller;
// false on a thrown error.
bool vm_to_primitive(VM* vm, Value v, i32 hint, Value* out) {
    if value_is_primitive(v) {
        *out = v;
        return true;
    }
    // Symbol.toPrimitive takes precedence when present and callable.
    Value exotic;
    if !vm_get_prop_value(vm, v, vm.sym_to_primitive_id, &exotic) { return false; }
    if value_is_callable(exotic) {
        str hs = "default";
        if hint == HINT_STRING { hs = "string"; }
        if hint == HINT_NUMBER { hs = "number"; }
        GcString* hg = gc_new_string(&vm.heap, hs);
        Value ha = value_cell(&hg.head);
        vpush(vm, ha);                       // root the hint string
        Value r = vm_call_value(vm, exotic, v, &ha, 1);
        vm.sp--;
        if vm.has_pending { return false; }
        if value_is_primitive(r) {
            *out = r;
            return true;
        }
        vm_throw_error(vm, ERR_TYPE, "Cannot convert object to a primitive value");
        return false;
    }
    bool prefer_string = hint == HINT_STRING;
    u32 first = prefer_string ? atom_intern(&vm.atoms, "toString")
        : atom_intern(&vm.atoms, "valueOf");
    u32 second = prefer_string ? atom_intern(&vm.atoms, "valueOf")
        : atom_intern(&vm.atoms, "toString");
    u32[2] methods = { first, second };
    for i32 i = 0; i < 2; i++ {
        Value m;
        if !vm_get_prop_value(vm, v, methods[i], &m) { return false; }
        if value_is_callable(m) {
            Value dummy = value_undefined();
            Value r = vm_call_value(vm, m, v, &dummy, 0);
            if vm.has_pending { return false; }
            if value_is_primitive(r) {
                *out = r;
                return true;
            }
        }
    }
    vm_throw_error(vm, ERR_TYPE, "cannot convert object to a primitive value");
    return false;
}

private bool inspect_ident_key(str k) {
    if k.len == 0 { return false; }
    u8 c0 = *(k.data);
    if !((c0 >= 'a' && c0 <= 'z') || (c0 >= 'A' && c0 <= 'Z') || c0 == '_' || c0 == '$') {
        return false;
    }
    for i32 i = 1; i < k.len; i++ {
        u8 c = *(k.data + i);
        if !((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
            || c == '_' || c == '$') {
            return false;
        }
    }
    return true;
}

// Node's terminal width. Every layout decision below is relative to it: what
// fits on one line stays on one line.
const i32 INSPECT_WIDTH = 80;
// How many entries of an array or a collection are shown before the rest are
// counted off.
const i32 INSPECT_MAX_ENTRIES = 100;
// How much of a string is shown when it is being quoted.
const i32 INSPECT_MAX_STRING = 10000;

// One inspection's bookkeeping: what is currently being formatted (to spot a
// cycle) and which of those a cycle pointed back at (position gives the id
// node prints).
private struct InspectCtx {
    Vec<u64> seen;
    Vec<u64> circ;
}

private i32 inspect_circ_id(InspectCtx* cx, u64 id) {
    for i32 i = 0; i < cx.circ.len; i++ {
        if vec_get(&cx.circ, i) == id { return i + 1; }
    }
    return 0;
}

private void inspect_quoted(str_buf* sb, str s) {
    // Single quotes, unless the text carries one of its own: then double
    // quotes, or a backtick when it carries both. Node picks the delimiter the
    // same way, and escapes the control characters whichever it picks.
    bool has_single = false;
    bool has_double = false;
    bool has_back = false;
    for i32 i = 0; i < s.len; i++ {
        u8 c = *(s.data + i);
        if c == '\'' { has_single = true; }
        if c == '"' { has_double = true; }
        if c == '`' { has_back = true; }
        if c == '$' && i + 1 < s.len && *(s.data + i + 1) == '{' { has_back = true; }
    }
    u8 q = cast(u8, '\'');
    if has_single && !has_double { q = cast(u8, '"'); }
    else if has_single && has_double && !has_back { q = cast(u8, '`'); }
    i32 shown = s.len;
    if shown > INSPECT_MAX_STRING { shown = INSPECT_MAX_STRING; }
    str hexd = "0123456789ABCDEF";
    str_buf_add_byte(sb, q);
    for i32 i = 0; i < shown; i++ {
        u8 c = *(s.data + i);
        if c == q { str_buf_add(sb, "\\"); str_buf_add_byte(sb, c); }
        else if c == '\\' { str_buf_add(sb, "\\\\"); }
        else if c == '\n' { str_buf_add(sb, "\\n"); }
        else if c == '\t' { str_buf_add(sb, "\\t"); }
        else if c == '\r' { str_buf_add(sb, "\\r"); }
        else if c == 8 { str_buf_add(sb, "\\b"); }
        else if c == 11 { str_buf_add(sb, "\\v"); }
        else if c == 12 { str_buf_add(sb, "\\f"); }
        else if c < 0x20 || c == 0x7F {
            str_buf_add(sb, "\\x");
            str_buf_add_byte(sb, *(hexd.data + (c >> 4)));
            str_buf_add_byte(sb, *(hexd.data + (c & 15)));
        }
        else {
            str one;
            one.data = s.data + i;
            one.len = 1;
            str_buf_add(sb, one);
        }
    }
    str_buf_add_byte(sb, q);
    if s.len > shown {
        i32 rest = s.len - shown;
        string more;
        if rest == 1 { more = format("... {} more character", rest); }
        else { more = format("... {} more characters", rest); }
        str_buf_add(sb, more);
        free(more);
    }
}

// The name console output prefixes an object with: the name of the
// constructor owned by the nearest prototype that declares one, and only when
// the object really is one of those. Empty for a plain object.
private str inspect_ctor_name(VM* vm, JsObject* o) {
    str none = "";
    u32 ca = atom_intern(&vm.atoms, "constructor");
    JsObject* p = o.proto;
    while p != null {
        Value* c = props_get(&p.props, ca);
        if c != null {
            str nm = none;
            JsObject* home = null;
            if value_is_function(*c) {
                FnTemplate* ft = value_as_function(*c).tmpl;
                if ft != null { nm = ft.name; }
                Value* pr = props_get(&value_as_function(*c).props, vm.atom_prototype);
                if pr != null && value_is_object(*pr) { home = value_as_object(*pr); }
            } else if value_is_native(*c) {
                nm = value_as_native(*c).name;
                Value* pr = props_get(&value_as_native(*c).props, vm.atom_prototype);
                if pr != null && value_is_object(*pr) { home = value_as_object(*pr); }
            }
            // The declared constructor has to be one this object is an
            // instance of. Object.create({constructor: f}) borrows the name
            // without inheriting from f, and node ignores it.
            bool owns = false;
            JsObject* w = o.proto;
            while w != null {
                if w == home { owns = true; }
                w = w.proto;
            }
            if !owns { return none; }
            if nm.len == 0 || str_equal(nm, "Object") { return none; }
            return nm;
        }
        p = p.proto;
    }
    return none;
}

// Whether `p` is anywhere on o's prototype chain.
private bool inspect_proto_has(JsObject* o, JsObject* p) {
    if p == null { return false; }
    JsObject* cur = o.proto;
    while cur != null {
        if cur == p { return true; }
        cur = cur.proto;
    }
    return false;
}

// An inherited Symbol.toStringTag names the object in front of its braces.
// An own one does not: it is shown as an ordinary key instead.
private str inspect_tag(VM* vm, JsObject* o) {
    str none = "";
    u32 ta = vm_sym_to_string_tag_id(vm);
    if props_get(&o.props, ta) != null { return none; }
    JsObject* p = o.proto;
    while p != null {
        Value* t = props_get(&p.props, ta);
        if t != null {
            if value_is_string(*t) { return gc_string_view(value_as_string(*t)); }
            return none;
        }
        p = p.proto;
    }
    return none;
}

private void inspect_pad(str_buf* sb, i32 n) {
    for i32 i = 0; i < n; i++ { str_buf_add_byte(sb, cast(u8, ' ')); }
}

// Entries are written end to end into one buffer, with a start offset each
// and a terminating offset, so a length is a subtraction.
private str inspect_entry(str_buf* eb, Vec<i32>* off, i32 i) {
    str s;
    s.data = eb.data + vec_get(off, i);
    s.len = vec_get(off, i + 1) - vec_get(off, i);
    return s;
}

// Node lays short array entries out in columns rather than one per line. The
// column count comes from the average entry width; each column is padded to
// its widest member, to the right for numbers and to the left otherwise.
// False when the entries are too wide for that to help.
private bool inspect_group(str_buf* eb, Vec<i32>* off, i32 indent, bool numeric,
                           bool has_more, str_buf* rows, Vec<i32>* roff) {
    i32 n = off.len - 1;
    i32 count = has_more ? n - 1 : n;
    if count < 1 { return false; }
    i32 total = 0;
    i32 maxlen = 0;
    for i32 i = 0; i < count; i++ {
        i32 l = inspect_entry(eb, off, i).len;
        total += l + 2;
        if l > maxlen { maxlen = l; }
    }
    i32 amax = maxlen + 2;
    if amax * 3 + indent >= INSPECT_WIDTH { return false; }
    if cast(f64, total) / cast(f64, amax) <= 5.0 && maxlen > 6 { return false; }
    f64 bias = sqrt(cast(f64, amax) - cast(f64, total) / cast(f64, n));
    f64 bmax = cast(f64, amax) - 3.0 - bias;
    if bmax < 1.0 { bmax = 1.0; }
    i32 columns = cast(i32, floor(sqrt(2.5 * bmax * cast(f64, count)) / bmax + 0.5));
    i32 fitting = (INSPECT_WIDTH - indent) / amax;
    if columns > fitting { columns = fitting; }
    if columns > 12 { columns = 12; }
    if columns <= 1 { return false; }
    Vec<i32> width = vec_new<i32>(columns);
    for i32 c = 0; c < columns; c++ {
        i32 w = 0;
        i32 j = c;
        while j < count {
            i32 l = inspect_entry(eb, off, j).len;
            if l > w { w = l; }
            j += columns;
        }
        vec_push(&width, w + 2);
    }
    i32 i = 0;
    while i < count {
        i32 last = i + columns;
        if last > count { last = count; }
        vec_push(roff, rows.len);
        for i32 j = i; j < last; j++ {
            str e = inspect_entry(eb, off, j);
            i32 w = vec_get(&width, j - i);
            if j < last - 1 {
                if numeric { inspect_pad(rows, w - 2 - e.len); }
                str_buf_add(rows, e);
                str_buf_add(rows, ", ");
                if !numeric { inspect_pad(rows, w - 2 - e.len); }
            } else {
                if numeric { inspect_pad(rows, w - 2 - e.len); }
                str_buf_add(rows, e);
            }
        }
        i = last;
    }
    if has_more {
        vec_push(roff, rows.len);
        str_buf_add(rows, inspect_entry(eb, off, n - 1));
    }
    vec_push(roff, rows.len);
    vec_free(&width);
    return true;
}

// Entries onto one line if they fit in the width, else one per line at this
// indentation. `head` is what sits in front of the brace (a constructor name,
// a collection's size); `base` is a function's own rendering, which keeps its
// braces only when it carries properties.
private void inspect_layout(str_buf* sb, str prefix, str head, str base, bool arraylike,
                            str_buf* eb, Vec<i32>* off, i32 indent,
                            bool group, bool numeric, bool has_more) {
    i32 n = off.len - 1;
    if prefix.len > 0 { str_buf_add(sb, prefix); }
    if base.len > 0 {
        str_buf_add(sb, base);
        if n == 0 { return; }
        str_buf_add(sb, " ");
    }
    str_buf_add(sb, head);
    if n == 0 {
        str_buf_add(sb, arraylike ? "[]" : "{}");
        return;
    }
    str_buf rows;
    str_buf_init(&rows);
    Vec<i32> roff = vec_new<i32>(8);
    bool grouped = false;
    if group && n > 6 {
        grouped = inspect_group(eb, off, indent, numeric, has_more, &rows, &roff);
    }
    bool one_line = !grouped;
    if one_line {
        i32 total = n + n + indent + head.len + 1 + base.len + 10;
        if total + n > INSPECT_WIDTH { one_line = false; }
        for i32 i = 0; i < n; i++ {
            if !one_line { break; }
            str e = inspect_entry(eb, off, i);
            total += e.len;
            if total > INSPECT_WIDTH { one_line = false; }
            for i32 k = 0; k < e.len; k++ {
                if *(e.data + k) == '\n' { one_line = false; }
            }
        }
    }
    str_buf_add(sb, arraylike ? "[" : "{");
    if one_line {
        str_buf_add(sb, " ");
        for i32 i = 0; i < n; i++ {
            if i > 0 { str_buf_add(sb, ", "); }
            str_buf_add(sb, inspect_entry(eb, off, i));
        }
        str_buf_add(sb, " ");
    } else {
        str_buf* src = grouped ? &rows : eb;
        Vec<i32>* soff = grouped ? &roff : off;
        i32 rn = soff.len - 1;
        for i32 i = 0; i < rn; i++ {
            if i > 0 { str_buf_add(sb, ","); }
            str_buf_add(sb, "\n");
            inspect_pad(sb, indent + 2);
            str_buf_add(sb, inspect_entry(src, soff, i));
        }
        str_buf_add(sb, "\n");
        inspect_pad(sb, indent);
    }
    str_buf_add(sb, arraylike ? "]" : "}");
    str_buf_free(&rows);
    vec_free(&roff);
}

// Renders an object whose meaning is not in its enumerable properties: an
// error, a date, a regular expression, a Buffer, a boxed primitive. Returns
// false for anything ordinary. `ov` is `o` as a Value, for property reads.
private bool inspect_special(VM* vm, str_buf* sb, JsObject* o, Value ov) {
    // an error prints as its stack, which already begins "Name: message"
    if vm.error_protos[ERR_ERROR] != null && inspect_proto_has(o, vm.error_protos[ERR_ERROR]) {
        Value sv;
        if vm_get_prop_value(vm, ov, atom_intern(&vm.atoms, "stack"), &sv)
           && value_is_string(sv) {
            str_buf_add(sb, gc_string_view(value_as_string(sv)));
            return true;
        }
        Value mv;
        ignore vm_get_prop_value(vm, ov, atom_intern(&vm.atoms, "message"), &mv);
        Value nv;
        ignore vm_get_prop_value(vm, ov, atom_intern(&vm.atoms, "name"), &nv);
        if value_is_string(nv) { str_buf_add(sb, gc_string_view(value_as_string(nv))); }
        else { str_buf_add(sb, "Error"); }
        if value_is_string(mv) && value_as_string(mv).len > 0 {
            str_buf_add(sb, ": ");
            str_buf_add(sb, gc_string_view(value_as_string(mv)));
        }
        return true;
    }
    if vm.date_proto != null && inspect_proto_has(o, vm.date_proto) {
        Value s;
        if vm_get_prop_value(vm, ov, atom_intern(&vm.atoms, "toISOString"), &s)
           && value_is_callable(s) {
            Value dummy = value_undefined();
            Value r = vm_call_value(vm, s, ov, &dummy, 0);
            if vm.has_pending {
                // an invalid date has no ISO form; node says so rather than
                // propagating the RangeError out of a debug print
                vm.has_pending = false;
                vm.pending = value_undefined();
                str_buf_add(sb, "Invalid Date");
                return true;
            }
            if value_is_string(r) { str_buf_add(sb, gc_string_view(value_as_string(r))); return true; }
        }
        str_buf_add(sb, "Invalid Date");
        return true;
    }
    if vm.regexp_proto != null && inspect_proto_has(o, vm.regexp_proto) {
        Value src;
        Value fl;
        ignore vm_get_prop_value(vm, ov, atom_intern(&vm.atoms, "source"), &src);
        ignore vm_get_prop_value(vm, ov, atom_intern(&vm.atoms, "flags"), &fl);
        str_buf_add(sb, "/");
        if value_is_string(src) { str_buf_add(sb, gc_string_view(value_as_string(src))); }
        str_buf_add(sb, "/");
        if value_is_string(fl) { str_buf_add(sb, gc_string_view(value_as_string(fl))); }
        return true;
    }
    if vm.buffer_proto != null && o.proto == vm.buffer_proto {
        // node shows the bytes in hex, which is what makes a Buffer readable
        str hexd = "0123456789abcdef";
        str_buf_add(sb, "<Buffer");
        i32 shown = o.elen < 50 ? o.elen : 50;
        for i32 i = 0; i < shown; i++ {
            Value e = js_array_get(o, i);
            i32 by = value_is_number(e) ? (cast(i32, js_to_number(e)) & 255) : 0;
            str_buf_add(sb, " ");
            str_buf_add_byte(sb, *(hexd.data + (by >> 4)));
            str_buf_add_byte(sb, *(hexd.data + (by & 15)));
        }
        if o.elen > shown {
            string more = format(" ... {} more bytes", o.elen - shown);
            str_buf_add(sb, more);
            free(more);
        }
        str_buf_add(sb, ">");
        return true;
    }
    // a boxed primitive shows the value it wraps
    Value* pv = props_get(&o.props, atom_intern(&vm.atoms, "%prim"));
    if pv != null {
        str_buf_add(sb, "[");
        if value_is_string(*pv) { str_buf_add(sb, "String: "); }
        else if value_is_bool(*pv) { str_buf_add(sb, "Boolean: "); }
        else { str_buf_add(sb, "Number: "); }
        InspectCtx inner;
        inner.seen = vec_new<u64>(2);
        inner.circ = vec_new<u64>(2);
        inspect_into(vm, sb, *pv, 0, true, &inner, 0);
        vec_free(&inner.seen);
        vec_free(&inner.circ);
        str_buf_add(sb, "]");
        return true;
    }
    return false;
}

// A function's own rendering, before any properties it carries.
private void inspect_fn_base(VM* vm, str_buf* sb, Value v) {
    str nm;
    nm.data = null;
    nm.len = 0;
    bool is_class = false;
    bool is_gen = false;
    bool is_async = false;
    if value_is_native(v) { nm = value_as_native(v).name; }
    else if value_as_function(v).tmpl != null {
        FnTemplate* ft = value_as_function(v).tmpl;
        nm = ft.name;
        is_class = ft.is_class;
        is_gen = ft.is_gen;
        is_async = ft.is_async;
    }
    if is_class {
        str_buf_add(sb, "[class ");
        if nm.len > 0 { str_buf_add(sb, nm); } else { str_buf_add(sb, "(anonymous)"); }
        // the class it extends, which is its own [[Prototype]]
        Value fp = value_as_function(v).fproto;
        if value_is_function(fp) && value_as_function(fp).tmpl != null
            && value_as_function(fp).tmpl.name.len > 0 {
            str_buf_add(sb, " extends ");
            str_buf_add(sb, value_as_function(fp).tmpl.name);
        }
        str_buf_add(sb, "]");
        return;
    }
    str_buf_add(sb, "[");
    if is_async { str_buf_add(sb, "Async"); }
    if is_gen { str_buf_add(sb, "Generator"); }
    str_buf_add(sb, "Function");
    if nm.len > 0 {
        str_buf_add(sb, ": ");
        str_buf_add(sb, nm);
    } else {
        str_buf_add(sb, " (anonymous)");
    }
    str_buf_add(sb, "]");
}

// Own enumerable properties, string-keyed and symbol-keyed, as "key: value"
// entries. Shared by objects, functions that carry properties, and the tail
// of an array.
private void inspect_props(VM* vm, PropList* props, i32 depth, InspectCtx* cx, i32 indent,
                           str_buf* eb, Vec<i32>* off) {
    vm_props_order(vm, props);
    for i32 i = 0; i < props.len; i++ {
        Prop* pr = props.items + i;
        if !prop_copyable(vm, pr) { continue; }
        vec_push(off, eb.len);
        if (pr.key & 0x80000000) != 0 {
            string sym = vm_atom_display(vm, pr.key);
            str_buf_add(eb, "[");
            str_buf_add(eb, sym);
            str_buf_add(eb, "]");
            free(sym);
        } else {
            str kn = atom_name(&vm.atoms, pr.key);
            if inspect_ident_key(kn) { str_buf_add(eb, kn); }
            else { inspect_quoted(eb, kn); }
        }
        str_buf_add(eb, ": ");
        if value_is_accessor(pr.val) {
            JsAccessor* ac = value_as_accessor(pr.val);
            bool has_get = value_is_callable(ac.get);
            bool has_set = value_is_callable(ac.set);
            if has_get && has_set { str_buf_add(eb, "[Getter/Setter]"); }
            else if has_set { str_buf_add(eb, "[Setter]"); }
            else { str_buf_add(eb, "[Getter]"); }
        } else {
            inspect_into(vm, eb, pr.val, depth - 1, true, cx, indent + 2);
        }
    }
}

private void inspect_into(VM* vm, str_buf* sb, Value v, i32 depth, bool nested,
                          InspectCtx* cx, i32 indent) {
    if value_is_string(v) {
        if nested { inspect_quoted(sb, gc_string_view(value_as_string(v))); }
        else { str_buf_add(sb, gc_string_view(value_as_string(v))); }
        return;
    }
    if value_is_bigint(v) {
        string s = bn_to_str(bigint_view(value_as_bigint(v)));
        str_buf_add(sb, s);
        str_buf_add(sb, "n");
        free(s);
        return;
    }
    if value_is_double(v) && value_as_f64(v) == 0.0 && 1.0 / value_as_f64(v) < 0.0 {
        str_buf_add(sb, "-0");
        return;
    }
    if value_is_number(v) || value_is_bool(v) || value_is_null(v)
        || value_is_undefined(v) || value_is_symbol(v) {
        i32 rm = gc_root_mark(&vm.heap);
        Value s = value_is_symbol(v) ? vm_symbol_desc(vm, v) : js_to_string_value(vm, v);
        gc_root(&vm.heap, s);
        str_buf_add(sb, gc_string_view(value_as_string(s)));
        gc_root_reset(&vm.heap, rm);
        return;
    }
    bool composite = value_is_array(v) || value_is_object(v) || value_is_map(v)
        || value_is_generator(v) || value_is_function(v) || value_is_native(v);
    if !composite {
        str_buf_add(sb, "[object]");
        return;
    }
    // A value already being formatted is a cycle. Node numbers those and
    // marks the outermost rendering with a matching label.
    u64 id = v.bits;
    for i32 i = 0; i < cx.seen.len; i++ {
        if vec_get(&cx.seen, i) == id {
            i32 cid = inspect_circ_id(cx, id);
            if cid == 0 {
                vec_push(&cx.circ, id);
                cid = cx.circ.len;
            }
            string s = format("[Circular *{}]", cid);
            str_buf_add(sb, s);
            free(s);
            return;
        }
    }

    str empty = "";
    str_buf base;
    str_buf_init(&base);
    str_buf head;
    str_buf_init(&head);
    str_buf eb;
    str_buf_init(&eb);
    Vec<i32> off = vec_new<i32>(8);
    bool arraylike = false;
    bool group = false;
    bool numeric = false;
    bool has_more = false;
    bool bail = false;

    vec_push(&cx.seen, id);
    if value_is_function(v) || value_is_native(v) {
        inspect_fn_base(vm, &base, v);
        PropList* props = value_is_native(v) ? &value_as_native(v).props : &value_as_function(v).props;
        inspect_props(vm, props, depth, cx, indent, &eb, &off);
    } else if value_is_generator(v) {
        str_buf_add(&head, value_as_generator(v).is_async ? "Object [AsyncGenerator] " : "Object [Generator] ");
    } else if value_is_map(v) {
        JsMap* mp = value_as_map(v);
        if mp.weak {
            str_buf_add(&head, mp.is_set ? "WeakSet " : "WeakMap ");
            vec_push(&off, eb.len);
            str_buf_add(&eb, "<items unknown>");
        } else {
            str_buf_add(&head, mp.is_set ? "Set(" : "Map(");
            string cnt = format("{}) ", mp.count);
            str_buf_add(&head, cnt);
            free(cnt);
            i32 shown = 0;
            for i32 i = 0; i < mp.len; i++ {
                if !*(mp.live + i) { continue; }
                if shown >= INSPECT_MAX_ENTRIES { break; }
                shown++;
                vec_push(&off, eb.len);
                inspect_into(vm, &eb, *(mp.keys + i), depth - 1, true, cx, indent + 2);
                if !mp.is_set {
                    str_buf_add(&eb, " => ");
                    inspect_into(vm, &eb, *(mp.vals + i), depth - 1, true, cx, indent + 2);
                }
            }
            if mp.count > shown {
                has_more = true;
                vec_push(&off, eb.len);
                string more;
                if mp.count - shown == 1 { more = format("... {} more item", mp.count - shown); }
                else { more = format("... {} more items", mp.count - shown); }
                str_buf_add(&eb, more);
                free(more);
            }
        }
    } else {
        JsObject* o = value_as_object(v);
        if (o.obj_flags & OBJF_PROXY) != 0 {
            // node shows what the proxy stands for, not the proxy
            ignore vec_pop(&cx.seen);
            str_buf_free(&base);
            str_buf_free(&head);
            str_buf_free(&eb);
            vec_free(&off);
            inspect_into(vm, sb, cast(JsProxy*, o).target, depth, nested, cx, indent);
            return;
        }
        if vm.arraybuffer_proto != null && o.proto == vm.arraybuffer_proto && o.elen > 0
            && value_is_bytes(*(o.elems)) {
            // the bytes are the point of it, the way node shows them
            str_buf_add(&head, "ArrayBuffer ");
            GcBytes* gb = value_as_bytes(*(o.elems));
            i32 blen = gb.len;
            i32 shown = blen < INSPECT_MAX_ENTRIES ? blen : INSPECT_MAX_ENTRIES;
            str hexd = "0123456789abcdef";
            vec_push(&off, eb.len);
            str_buf_add(&eb, "[Uint8Contents]: <");
            for i32 i = 0; i < shown; i++ {
                if i > 0 { str_buf_add(&eb, " "); }
                u8 by = *(gb_data(gb) + i);
                str_buf_add_byte(&eb, *(hexd.data + (by >> 4)));
                str_buf_add_byte(&eb, *(hexd.data + (by & 15)));
            }
            if blen > shown {
                string more;
                if blen - shown == 1 { more = format(" ... {} more byte", blen - shown); }
                else { more = format(" ... {} more bytes", blen - shown); }
                str_buf_add(&eb, more);
                free(more);
            }
            str_buf_add(&eb, ">");
            vec_push(&off, eb.len);
            string bl = format("byteLength: {}", blen);
            str_buf_add(&eb, bl);
            free(bl);
        } else if (o.obj_flags & OBJF_TYPEDARRAY) != 0 {
            i32 kind = ta_prop_int(vm, o, vm.atom_ta_kind);
            i32 len = ta_prop_int(vm, o, vm.atom_ta_len);
            if depth < 0 {
                str_buf_add(sb, "[");
                str_buf_add(sb, ta_kind_name(kind));
                str_buf_add(sb, "]");
                bail = true;
            } else {
                str_buf_add(&head, ta_kind_name(kind));
                string hdr = format("({}) ", len);
                str_buf_add(&head, hdr);
                free(hdr);
                arraylike = true;
                group = true;
                numeric = true;
                i32 shown = len < INSPECT_MAX_ENTRIES ? len : INSPECT_MAX_ENTRIES;
                for i32 i = 0; i < shown; i++ {
                    vec_push(&off, eb.len);
                    inspect_into(vm, &eb, vm_ta_get(vm, o, i), depth - 1, true, cx, indent + 2);
                }
                if len > shown {
                    has_more = true;
                    vec_push(&off, eb.len);
                    string more;
                    if len - shown == 1 { more = format("... {} more item", len - shown); }
                    else { more = format("... {} more items", len - shown); }
                    str_buf_add(&eb, more);
                    free(more);
                }
            }
        } else if inspect_special(vm, sb, o, v) {
            bail = true;
        } else if depth < 0 {
            str_buf_add(sb, (o.obj_flags & OBJF_ARRAY) != 0 ? "[Array]" : "[Object]");
            bail = true;
        } else if (o.obj_flags & OBJF_ARRAY) != 0 {
            arraylike = true;
            group = true;
            numeric = true;
            i32 shown = o.elen < INSPECT_MAX_ENTRIES ? o.elen : INSPECT_MAX_ENTRIES;
            i32 i = 0;
            while i < shown {
                vec_push(&off, eb.len);
                if value_is_hole(js_array_raw(o, i)) {
                    // a run of holes counts itself off
                    i32 run = 0;
                    while i < shown && value_is_hole(js_array_raw(o, i)) {
                        run++;
                        i++;
                    }
                    string s;
                    if run == 1 { s = format("<{} empty item>", run); }
                    else { s = format("<{} empty items>", run); }
                    str_buf_add(&eb, s);
                    free(s);
                    numeric = false;
                } else {
                    Value el = js_array_get(o, i);
                    if !value_is_number(el) { numeric = false; }
                    inspect_into(vm, &eb, el, depth - 1, true, cx, indent + 2);
                    i++;
                }
            }
            if o.elen > shown {
                has_more = true;
                vec_push(&off, eb.len);
                string more;
                if o.elen - shown == 1 { more = format("... {} more item", o.elen - shown); }
                else { more = format("... {} more items", o.elen - shown); }
                str_buf_add(&eb, more);
                free(more);
            }
            i32 before = off.len;
            inspect_props(vm, &o.props, depth, cx, indent, &eb, &off);
            if off.len > before { numeric = false; }
        } else {
            // a promise is its state, not its slots
            Value* st = props_get(&o.props, vm.atom_pstate);
            if st != null {
                str_buf_add(&head, "Promise ");
                i32 state = value_is_int(*st) ? value_as_int(*st) : 0;
                vec_push(&off, eb.len);
                if state == 0 { str_buf_add(&eb, "<pending>"); }
                else {
                    if state == 2 { str_buf_add(&eb, "<rejected> "); }
                    Value* pval = props_get(&o.props, vm.atom_pvalue);
                    if pval != null {
                        inspect_into(vm, &eb, *pval, depth - 1, true, cx, indent + 2);
                    }
                }
            } else {
                if o.proto == null {
                    str_buf_add(&head, "[Object: null prototype] ");
                } else {
                    str cn = inspect_ctor_name(vm, o);
                    str tag = inspect_tag(vm, o);
                    if tag.len > 0 && !str_equal(tag, cn) {
                        str_buf_add(&head, cn.len > 0 ? cn : "Object");
                        str_buf_add(&head, " [");
                        str_buf_add(&head, tag);
                        str_buf_add(&head, "] ");
                    } else if cn.len > 0 {
                        str_buf_add(&head, cn);
                        str_buf_add(&head, " ");
                    }
                }
                inspect_props(vm, &o.props, depth, cx, indent, &eb, &off);
            }
        }
    }
    ignore vec_pop(&cx.seen);
    if !bail {
        vec_push(&off, eb.len);
        str_buf pre;
        str_buf_init(&pre);
        i32 cid = inspect_circ_id(cx, id);
        if cid > 0 {
            string s = format("<ref *{}> ", cid);
            str_buf_add(&pre, s);
            free(s);
        }
        str prefix = pre.len > 0 ? str_buf_to_str(&pre) : empty;
        str headv = head.len > 0 ? str_buf_to_str(&head) : empty;
        str basev = base.len > 0 ? str_buf_to_str(&base) : empty;
        inspect_layout(sb, prefix, headv, basev, arraylike, &eb, &off, indent,
            group, numeric, has_more);
        str_buf_free(&pre);
    }
    str_buf_free(&base);
    str_buf_free(&head);
    str_buf_free(&eb);
    vec_free(&off);
}

// Display form for console: primitives as ToString (with -0 shown),
// objects/arrays via a Node-like inspect.
// A string in the quoting inspect uses for a nested one, for callers that
// want the quoted form at the top level too (util.inspect does; console does
// not).
Value vm_quoted_string(VM* vm, str s) {
    str_buf sb;
    str_buf_init(&sb);
    inspect_quoted(&sb, s);
    GcString* g = gc_new_string(&vm.heap, str_buf_to_str(&sb));
    str_buf_free(&sb);
    return value_cell(&g.head);
}

// Nesting below this is elided as [Object] / [Array]. Node's default, and the
// reason printing a deep or recursive structure stays readable.
const i32 INSPECT_DEPTH = 2;

Value vm_inspect_depth(VM* vm, Value v, i32 depth) {
    str_buf sb;
    str_buf_init(&sb);
    InspectCtx cx;
    cx.seen = vec_new<u64>(8);
    cx.circ = vec_new<u64>(4);
    inspect_into(vm, &sb, v, depth, false, &cx, 0);
    vec_free(&cx.seen);
    vec_free(&cx.circ);
    GcString* g = gc_new_string(&vm.heap, str_buf_to_str(&sb));
    str_buf_free(&sb);
    return value_cell(&g.head);
}

Value js_console_string(VM* vm, Value v) {
    if value_is_object(v) || value_is_array(v) || value_is_map(v)
        || value_is_function(v) || value_is_native(v) || value_is_bigint(v)
        || value_is_symbol(v) || value_is_generator(v)
        || (value_is_double(v) && value_as_f64(v) == 0.0 && 1.0 / value_as_f64(v) < 0.0) {
        return vm_inspect_depth(vm, v, INSPECT_DEPTH);
    }
    return js_to_string_value(vm, v);
}

private Value native_console_out(VM* vm, Value* args, i32 argc, bool to_err) {
    for i32 i = 0; i < argc; i++ {
        if i > 0 {
            if to_err { eprint(" "); } else { print(" "); }
        }
        Value s = js_console_string(vm, *(args + i));
        vpush(vm, s);
        str view = gc_string_view(value_as_string(s));
        // lone surrogates can't go to a UTF-8 sink; show U+FFFD
        if wtf8_has_surrogate(view) {
            str_buf sb;
            str_buf_init(&sb);
            wtf8_sanitize_into(&sb, view);
            str clean = str_buf_to_str(&sb);
            if to_err { eprint("{}", clean); } else { print("{}", clean); }
            str_buf_free(&sb);
        } else {
            if to_err { eprint("{}", view); } else { print("{}", view); }
        }
        vm.sp--;
    }
    if to_err { eprint("\n"); } else { print("\n"); }
    return value_undefined();
}

private Value native_console_log(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    return native_console_out(cast(VM*, vmp), args, argc, false);
}

private Value native_console_error(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    return native_console_out(cast(VM*, vmp), args, argc, true);
}

private void vm_install_globals(VM* vm) {
    vm_set_global(vm, "undefined", value_undefined());
    vm_set_global(vm, "NaN", value_number(0.0 / 0.0));
    vm_set_global(vm, "Infinity", value_number(1.0e308 * 10.0));
    JsObject* con = js_new_object(&vm.heap, null);
    vm_set_global(vm, "console", value_cell(&con.head));
    JsNative* log = js_new_native(&vm.heap, &native_console_log, "log");
    js_set_prop(con, atom_intern(&vm.atoms, "log"), value_cell(&log.head));
    JsNative* err = js_new_native(&vm.heap, &native_console_error, "error");
    js_set_prop(con, atom_intern(&vm.atoms, "error"), value_cell(&err.head));
}

// --- lifecycle -------------------------------------------------------------------------

void vm_init(VM* vm) {
    gc_init(&vm.heap);
    vm.heap.tracer = &js_trace;
    vm.heap.finalizer = &js_finalize;
    vm.heap.mark_roots = &vm_mark_roots;
    vm.heap.weak_mark = &vm_weak_mark;
    vm.heap.weak_sweep = &vm_weak_sweep;
    vm.heap.mark_ctx = cast(void*, vm);
    atoms_init(&vm.atoms);
    vm.stack = alloc<Value>(VM_STACK_MAX);
    vm.sp = 0;
    vm.frames = alloc<Frame>(VM_FRAMES_MAX);
    vm.fp = 0;
    vm.pending_new_target = value_undefined();
    vm.handlers = alloc<Handler>(VM_HANDLERS_MAX);
    vm.hp = 0;
    intmap_init<Value>(&vm.globals);
    vm.n_hidden_globals = 0;
    vm.main_module = null;
    vec_init<TmplPtr>(&vm.troots, 4);
    vm.pending = value_undefined();
    vm.has_pending = false;
    vm.unwind_return = false;
    vm.quiet_errors = false;
    vm.atom_length = atom_intern(&vm.atoms, "length");
    vm.atom_prototype = atom_intern(&vm.atoms, "prototype");
    vm.atom_name = atom_intern(&vm.atoms, "name");
    vm.atom_message = atom_intern(&vm.atoms, "message");
    vm.object_proto = null;
    vm.array_proto = null;
    vm.string_proto = null;
    vm.number_proto = null;
    vm.boolean_proto = null;
    vm.function_proto = null;
    for i32 i = 0; i < ERR_KIND_COUNT; i++ {
        vm.error_protos[i] = null;
    }
    vm.rng = cast(u64, vm) ^ 0x9E3779B97F4A7C15;
    vm.generator_proto = null;
    vm.async_generator_proto = null;
    vm.iterator_proto = null;
    vm.iter_helper_proto = null;
    vm.promise_proto = null;
    vm.regexp_proto = null;
    vm.map_proto = null;
    vm.set_proto = null;
    vm.weakmap_proto = null;
    vm.weakset_proto = null;
    vm.date_proto = null;
    vm.symbol_proto = null;
    vm.symbol_registry = null;
    vm.bigint_proto = null;
    vm.buffer_proto = null;
    vm.ta_proto = null;
    vm.arraybuffer_proto = null;
    vm.dataview_proto = null;
    for i32 i = 0; i < 9; i++ { vm.ta_protos[i] = null; }
    vm.textenc_proto = null;
    vm.textdec_proto = null;
    vm.timeout_proto = null;
    vm.node_fs_ns = null;
    vm.node_fsp_ns = null;
    vm.node_path_ns = null;
    vm.node_os_ns = null;
    vm.node_events_ns = null;
    vm.node_util_ns = null;
    vm.node_crypto_ns = null;
    vm.node_zlib_ns = null;
    vm.node_process_ns = null;
    vm.node_buffer_ns = null;
    vm.node_timers_ns = null;
    vm.crypto_hash_proto = null;
    vm.crypto_hmac_proto = null;
    vm.url_proto = null;
    vm.usp_proto = null;
    vm.require_cache = null;
    vec_init<RegexProgPtr>(&vm.regexps, 4);
    vm.atom_rx = atom_intern(&vm.atoms, "%rx");
    vm.atom_source = atom_intern(&vm.atoms, "source");
    vm.atom_flags = atom_intern(&vm.atoms, "flags");
    vm.atom_lastindex = atom_intern(&vm.atoms, "lastIndex");
    vm.atom_index = atom_intern(&vm.atoms, "index");
    vec_init<VmJob>(&vm.jobs, 8);
    vm.job_head = 0;
    vec_init<Value>(&vm.rejections, 4);
    vec_init<VmTimer>(&vm.timers, 4);
    vm.next_timer_id = 1;
    vm.timer_seq = 0;
    vec_init<IoHandle>(&vm.handles, 4);
    vm.reactor_hook = null;
    vm.dynimport_hook = null;
    vm.esm_loader = null;
    vm.arguments_builder = null;
    vec_init<Value>(&vm.symbols, 8);
    vm.sym_iterator = value_undefined();
    vm.sym_iterator_id = 0;
    vm.sym_to_primitive = value_undefined();
    vm.sym_to_primitive_id = 0;
    vm.sym_async_iterator = value_undefined();
    vm.sym_async_iterator_id = 0;
    vm.sym_to_string_tag = value_undefined();
    vm.sym_to_string_tag_id = 0;
    vm.sym_has_instance = value_undefined();
    vm.sym_has_instance_id = 0;
    vm.atom_pstate = atom_intern(&vm.atoms, "%state");
    vm.atom_pvalue = atom_intern(&vm.atoms, "%value");
    vm.atom_pcbs = atom_intern(&vm.atoms, "%cbs");
    vm.atom_phandled = atom_intern(&vm.atoms, "%handled");
    vm.atom_ta_off = atom_intern(&vm.atoms, "%taoff");
    vm.atom_ta_len = atom_intern(&vm.atoms, "%talen");
    vm.atom_ta_kind = atom_intern(&vm.atoms, "%takind");
    vm.atom_value = atom_intern(&vm.atoms, "value");
    vm.atom_done = atom_intern(&vm.atoms, "done");
    vm.atom_next = atom_intern(&vm.atoms, "next");
    vm.exec_depth = 0;
    vm_install_globals(vm);
    // Well-known symbols: allocated up front so their ids are stable and
    // shared as property keys.
    // Their descriptions are the spec-visible names, so `String(Symbol.iterator)`
    // reads "Symbol(Symbol.iterator)".
    Value itsym = vm_new_wellknown_symbol(vm, "Symbol.iterator");
    vm.sym_iterator = itsym;
    vm.sym_iterator_id = value_as_symbol(itsym).id;
    Value tpsym = vm_new_wellknown_symbol(vm, "Symbol.toPrimitive");
    vm.sym_to_primitive = tpsym;
    vm.sym_to_primitive_id = value_as_symbol(tpsym).id;
    Value aisym = vm_new_wellknown_symbol(vm, "Symbol.asyncIterator");
    vm.sym_async_iterator = aisym;
    vm.sym_async_iterator_id = value_as_symbol(aisym).id;
    Value ttsym = vm_new_wellknown_symbol(vm, "Symbol.toStringTag");
    vm.sym_to_string_tag = ttsym;
    vm.sym_to_string_tag_id = value_as_symbol(ttsym).id;
    Value hisym = vm_new_wellknown_symbol(vm, "Symbol.hasInstance");
    vm.sym_has_instance = hisym;
    vm.sym_has_instance_id = value_as_symbol(hisym).id;
}

void vm_destroy(VM* vm) {
    gc_destroy(&vm.heap);
    for i32 i = 0; i < vm.troots.len; i++ {
        template_free(vec_get(&vm.troots, i));
    }
    vec_free(&vm.troots);
    vec_free(&vm.jobs);
    vec_free(&vm.rejections);
    vec_free(&vm.timers);
    vec_free(&vm.handles);
    vec_free(&vm.symbols);
    for i32 i = 0; i < vm.regexps.len; i++ {
        regex_free(vec_get(&vm.regexps, i));
    }
    vec_free(&vm.regexps);
    intmap_free<Value>(&vm.globals);
    atoms_free(&vm.atoms);
    free(vm.stack);
    free(vm.frames);
    free(vm.handlers);
}

// --- dispatch loop -----------------------------------------------------------------------

private i32 rd_u16(u8* code, i32 at) {
    i32 lo = *(code + at);
    i32 hi = *(code + at + 1);
    return lo | (hi << 8);
}

private void print_uncaught(VM* vm, Value e) {
    if vm.quiet_errors { return; }
    if value_is_object(e) {
        // prefer the full stack (Name: message + frames)
        Value sv;
        if js_get_prop(value_as_object(e), atom_intern(&vm.atoms, "stack"), &sv)
            && value_is_string(sv) {
            eprint("Uncaught {}\n", gc_string_view(value_as_string(sv)));
            return;
        }
        Value nv;
        Value mv;
        if js_get_prop(value_as_object(e), vm.atom_name, &nv)
            && js_get_prop(value_as_object(e), vm.atom_message, &mv)
            && value_is_string(nv) && value_is_string(mv) {
            eprint("Uncaught {}: {}\n", gc_string_view(value_as_string(nv)),
                gc_string_view(value_as_string(mv)));
            return;
        }
    }
    Value s = js_to_string_value(vm, e);
    vpush(vm, s);
    eprint("Uncaught {}\n", gc_string_view(value_as_string(s)));
    vm.sp--;
}

// Executes until the frame count drops below stop_fp.
// 0 = completed (result on stack), 1 = uncaught exception (printed).
// Replaces the top two stack operands with their primitives (number
// hint) if either is a reference. false on a thrown error.
private bool coerce_top2_prim(VM* vm, i32 hint) {
    if value_is_primitive(vpeek(vm, 1)) && value_is_primitive(vpeek(vm, 0)) {
        return true;
    }
    Value pa;
    if !vm_to_primitive(vm, vpeek(vm, 1), hint, &pa) { return false; }
    *(vm.stack + vm.sp - 2) = pa;
    Value pb;
    if !vm_to_primitive(vm, vpeek(vm, 0), hint, &pb) { return false; }
    *(vm.stack + vm.sp - 1) = pb;
    return true;
}

// Arithmetic on two BigInts; throws RangeError on /0 or negative **.
private Value bigint_arith(VM* vm, Value av, Value bv, i32 op) {
    BigNum x = bigint_view(value_as_bigint(av));
    BigNum y = bigint_view(value_as_bigint(bv));
    BigNum r;
    bool ok = true;
    if op == OP_ADD { r = bn_add(x, y); }
    else if op == OP_SUB { r = bn_sub(x, y); }
    else if op == OP_MUL { r = bn_mul(x, y); }
    else if op == OP_DIV { BigNum rem; r = bn_divmod(x, y, &rem, &ok); bn_free(&rem); }
    else if op == OP_MOD { BigNum q = bn_divmod(x, y, &r, &ok); bn_free(&q); }
    else if op == OP_POW { r = bn_pow(x, y, &ok); }
    else { ok = false; r = bn_from_i64(0); }
    if !ok {
        bn_free(&r);
        vm_throw_error(vm, ERR_RANGE,
            op == OP_POW ? "Exponent must be non-negative" : "Division by zero");
        return value_undefined();
    }
    GcBigInt* g = js_new_bigint(&vm.heap, r);
    bn_free(&r);
    return value_cell(&g.head);
}

private Value bigint_negate(VM* vm, Value v) {
    BigNum r = bn_neg(bigint_view(value_as_bigint(v)));
    GcBigInt* g = js_new_bigint(&vm.heap, r);
    bn_free(&r);
    return value_cell(&g.head);
}

private Value bigint_step(VM* vm, Value v, bool inc) {
    BigNum one = bn_from_i64(inc ? 1 : -1);
    BigNum r = bn_add(bigint_view(value_as_bigint(v)), one);
    bn_free(&one);
    GcBigInt* g = js_new_bigint(&vm.heap, r);
    bn_free(&r);
    return value_cell(&g.head);
}

// Handles a BigInt operand in a binary arithmetic op: sets *out and
// returns true if it consumed the operands (both-BigInt result or a
// mixed-type throw). Returns false to fall through to numeric handling.
private bool try_bigint_op(VM* vm, Value a, Value b, i32 op, Value* out) {
    bool ab = value_is_bigint(a);
    bool bb = value_is_bigint(b);
    if !ab && !bb { return false; }
    if ab && bb {
        *out = bigint_arith(vm, a, b, op);
        return true;
    }
    vm_throw_error(vm, ERR_TYPE, "Cannot mix BigInt and other types, use explicit conversions");
    *out = value_undefined();
    return true;
}

private i32 vm_execute(VM* vm, i32 stop_fp) {
    Frame* fr = vm.frames + (vm.fp - 1);
    FnTemplate* t = fr.tmpl;
    u8* code = t.code;
    i32 ip = fr.ret_ip;   // 0 for calls; the resume point for generators

    while true {
        // top-of-loop so resuming a generator with a pending throw
        // unwinds before its first opcode
        if vm.has_pending {
            Handler* htop = vm.handlers + (vm.hp - 1);
            if vm.hp > 0 && htop.frame_count >= stop_fp {
                vm.hp--;
                Handler* h = vm.handlers + vm.hp;
                vm.fp = h.frame_count;
                vm.sp = h.sp;
                fr = vm.frames + (vm.fp - 1);
                t = fr.tmpl;
                code = t.code;
                ip = h.ip;
                vpush(vm, vm.pending);
                vm.pending = value_undefined();
                vm.has_pending = false;
            } else {
                while vm.hp > 0 {
                    Handler* hh = vm.handlers + (vm.hp - 1);
                    if hh.frame_count < stop_fp { break; }
                    vm.hp--;
                }
                while vm.fp >= stop_fp {
                    Frame* pf = vm.frames + (vm.fp - 1);
                    if pf.gen != null { pf.gen.state = GEN_DONE; }
                    vm.fp--;
                }
                return 1;
            }
        }
        i32 op = *(code + ip);
        ip++;
        switch op {
            case OP_CONST: {
                vpush(vm, *(t.consts + rd_u16(code, ip)));
                ip += 2;
            }
            case OP_UNDEF: { vpush(vm, value_undefined()); }
            case OP_HOLE: { vpush(vm, value_hole()); }
            case OP_NULL: { vpush(vm, value_null()); }
            case OP_TRUE: { vpush(vm, value_bool(true)); }
            case OP_FALSE: { vpush(vm, value_bool(false)); }
            case OP_POP: { vm.sp--; }
            case OP_DUP: { vpush(vm, vpeek(vm, 0)); }
            case OP_DUP2: {
                vpush(vm, vpeek(vm, 1));
                vpush(vm, vpeek(vm, 1));
            }
            case OP_THIS: { vpush(vm, fr.this_val); }
            case OP_ARGUMENTS: { vpush(vm, fr.arguments_obj); }
            case OP_CURFUNC: {
                if fr.fun != null { vpush(vm, value_cell(&fr.fun.head)); }
                else { vpush(vm, value_undefined()); }
            }
            case OP_NEWTARGET: { vpush(vm, fr.new_target); }
            case OP_DYNIMPORT: {
                // spec and referrer stay on the stack (rooted) across the hook,
                // which allocates the promise and may load/evaluate a module.
                Value spec = vpeek(vm, 1);
                Value referrer = vpeek(vm, 0);
                Value result = value_undefined();
                if vm.dynimport_hook != null {
                    result = vm.dynimport_hook(vm, spec, referrer);
                }
                vpop(vm);
                vpop(vm);
                vpush(vm, result);
            }
            case OP_GETLOCAL: {
                vpush(vm, *(vm.stack + fr.base + rd_u16(code, ip)));
                ip += 2;
            }
            case OP_GETLOCAL_CHK: {
                Value v = *(vm.stack + fr.base + rd_u16(code, ip));
                ip += 2;
                if value_is_hole(v) {
                    vm_throw_error(vm, ERR_REF, "cannot access variable before initialization");
                } else {
                    vpush(vm, v);
                }
            }
            case OP_SETLOCAL: {
                *(vm.stack + fr.base + rd_u16(code, ip)) = vpeek(vm, 0);
                ip += 2;
            }
            case OP_SETHOLE: {
                *(vm.stack + fr.base + rd_u16(code, ip)) = value_hole();
                ip += 2;
            }
            case OP_NEWCELL_UNDEF: {
                JsBox* b = js_new_box(&vm.heap, value_undefined());
                *(vm.stack + fr.base + rd_u16(code, ip)) = value_cell(&b.head);
                ip += 2;
            }
            case OP_NEWCELL_HOLE: {
                JsBox* b = js_new_box(&vm.heap, value_hole());
                *(vm.stack + fr.base + rd_u16(code, ip)) = value_cell(&b.head);
                ip += 2;
            }
            case OP_CELLIFY: {
                i32 slot = rd_u16(code, ip);
                ip += 2;
                JsBox* b = js_new_box(&vm.heap, *(vm.stack + fr.base + slot));
                *(vm.stack + fr.base + slot) = value_cell(&b.head);
            }
            case OP_GETCELL: {
                JsBox* b = value_as_box(*(vm.stack + fr.base + rd_u16(code, ip)));
                ip += 2;
                vpush(vm, b.v);
            }
            case OP_GETCELL_CHK: {
                JsBox* b = value_as_box(*(vm.stack + fr.base + rd_u16(code, ip)));
                ip += 2;
                if value_is_hole(b.v) {
                    vm_throw_error(vm, ERR_REF, "cannot access variable before initialization");
                } else {
                    vpush(vm, b.v);
                }
            }
            case OP_SETCELL: {
                JsBox* b = value_as_box(*(vm.stack + fr.base + rd_u16(code, ip)));
                ip += 2;
                b.v = vpeek(vm, 0);
            }
            case OP_GETUPVAL: {
                JsBox* b = value_as_box(*(fr.fun.upvals + rd_u16(code, ip)));
                ip += 2;
                vpush(vm, b.v);
            }
            case OP_GETUPVAL_CHK: {
                JsBox* b = value_as_box(*(fr.fun.upvals + rd_u16(code, ip)));
                ip += 2;
                if value_is_hole(b.v) {
                    vm_throw_error(vm, ERR_REF, "cannot access variable before initialization");
                } else {
                    vpush(vm, b.v);
                }
            }
            case OP_SETUPVAL: {
                JsBox* b = value_as_box(*(fr.fun.upvals + rd_u16(code, ip)));
                ip += 2;
                b.v = vpeek(vm, 0);
            }
            case OP_GETGLOBAL, OP_GETGLOBAL_SOFT: {
                u32 a = cast(u32, value_as_int(*(t.consts + rd_u16(code, ip))));
                ip += 2;
                Value* g = intmap_get<Value>(&vm.globals, a);
                if g != null {
                    Value gv0 = *g;
                    // a lazy global (see vm_set_lazy_global): an accessor
                    // resolves through its getter, so the value it stands for
                    // is only built when something actually reads the name
                    if value_is_accessor(gv0) {
                        JsAccessor* lac = value_as_accessor(gv0);
                        if value_is_callable(lac.get) {
                            Value dummy0 = value_undefined();
                            gv0 = vm_call_value(vm, lac.get, value_undefined(), &dummy0, 0);
                            if vm.has_pending { break case; }
                        } else {
                            gv0 = value_undefined();
                        }
                    }
                    vpush(vm, gv0);
                } else {
                    // Free identifiers resolve against the global object, which
                    // inherits Object.prototype, so bare `toString` /
                    // `hasOwnProperty` / `valueOf` (and `typeof` of them) work
                    // as in Node. Only the intmap-miss path pays this lookup.
                    Value gv;
                    if vm.object_proto != null
                       && vm_get_prop_value(vm, value_cell(&vm.object_proto.head), a, &gv)
                       && !value_is_undefined(gv) {
                        vpush(vm, gv);
                    } else if op == OP_GETGLOBAL_SOFT {
                        vpush(vm, value_undefined());
                    } else {
                        str nm = atom_name(&vm.atoms, a);
                        string msg = format("{} is not defined", nm);
                        vm_throw_error(vm, ERR_REF, msg);
                        free(msg);
                    }
                }
            }
            case OP_SETGLOBAL: {
                u32 a = cast(u32, value_as_int(*(t.consts + rd_u16(code, ip))));
                ip += 2;
                intmap_set<Value>(&vm.globals, a, vpeek(vm, 0));
            }
            case OP_ADD: {
                if !value_is_primitive(vpeek(vm, 0)) || !value_is_primitive(vpeek(vm, 1)) {
                    if !coerce_top2_prim(vm, HINT_DEFAULT) { break case; }
                }
                Value b = vpeek(vm, 0);
                Value a = vpeek(vm, 1);
                if value_is_int(a) && value_is_int(b) {
                    i64 s = cast(i64, value_as_int(a)) + value_as_int(b);
                    vm.sp -= 2;
                    if s >= -2147483648 && s <= 2147483647 {
                        vpush(vm, value_int(cast(i32, s)));
                    } else {
                        vpush(vm, value_number(cast(f64, s)));
                    }
                } else if value_is_number(a) && value_is_number(b) {
                    f64 r = js_to_number(a) + js_to_number(b);
                    vm.sp -= 2;
                    vpush(vm, num_norm(r));
                } else if value_is_string(a) || value_is_string(b) {
                    Value sa = js_to_string_value(vm, a);
                    vpush(vm, sa);
                    Value sb = js_to_string_value(vm, b);
                    vpush(vm, sb);
                    str va = gc_string_view(value_as_string(sa));
                    str vb = gc_string_view(value_as_string(sb));
                    GcString* g = cast(GcString*, gc_alloc(&vm.heap, GC_STRING,
                        sizeof(GcString) + va.len + vb.len));
                    g.len = va.len + vb.len;
                    g.u16len = value_as_string(sa).u16len + value_as_string(sb).u16len;
                    u8* dst = cast(u8*, g) + sizeof(GcString);
                    if va.len > 0 { memcpy(dst, va.data, va.len); }
                    if vb.len > 0 { memcpy(dst + va.len, vb.data, vb.len); }
                    vm.sp -= 4;
                    vpush(vm, value_cell(&g.head));
                } else if value_is_bigint(a) || value_is_bigint(b) {
                    Value r;
                    ignore try_bigint_op(vm, a, b, OP_ADD, &r);
                    vm.sp -= 2;
                    if !vm.has_pending { vpush(vm, r); }
                } else {
                    f64 r = vm_to_number(vm, a) + vm_to_number(vm, b);
                    vm.sp -= 2;
                    vpush(vm, num_norm(r));
                }
            }
            case OP_SUB: {
                if !value_is_primitive(vpeek(vm, 0)) || !value_is_primitive(vpeek(vm, 1)) {
                    if !coerce_top2_prim(vm, HINT_NUMBER) { break case; }
                }
                Value b = vpeek(vm, 0);
                Value a = vpeek(vm, 1);
                if value_is_int(a) && value_is_int(b) {
                    i64 s = cast(i64, value_as_int(a)) - value_as_int(b);
                    vm.sp -= 2;
                    if s >= -2147483648 && s <= 2147483647 {
                        vpush(vm, value_int(cast(i32, s)));
                    } else {
                        vpush(vm, value_number(cast(f64, s)));
                    }
                } else if value_is_bigint(a) || value_is_bigint(b) {
                    Value r;
                    ignore try_bigint_op(vm, a, b, OP_SUB, &r);
                    vm.sp -= 2;
                    if !vm.has_pending { vpush(vm, r); }
                } else {
                    f64 r = vm_to_number(vm, a) - vm_to_number(vm, b);
                    vm.sp -= 2;
                    vpush(vm, num_norm(r));
                }
            }
            case OP_MUL: {
                if !value_is_primitive(vpeek(vm, 0)) || !value_is_primitive(vpeek(vm, 1)) {
                    if !coerce_top2_prim(vm, HINT_NUMBER) { break case; }
                }
                Value b = vpeek(vm, 0);
                Value a = vpeek(vm, 1);
                if value_is_int(a) && value_is_int(b) {
                    i64 s = cast(i64, value_as_int(a)) * value_as_int(b);
                    vm.sp -= 2;
                    if s == 0 && (value_as_int(a) < 0 || value_as_int(b) < 0) {
                        // a zero product with one negative factor is -0, which
                        // the integer representation cannot hold
                        vpush(vm, value_number(-0.0));
                    } else if s >= -2147483648 && s <= 2147483647 {
                        vpush(vm, value_int(cast(i32, s)));
                    } else {
                        vpush(vm, value_number(cast(f64, s)));
                    }
                } else if value_is_bigint(a) || value_is_bigint(b) {
                    Value r;
                    ignore try_bigint_op(vm, a, b, OP_MUL, &r);
                    vm.sp -= 2;
                    if !vm.has_pending { vpush(vm, r); }
                } else {
                    f64 r = vm_to_number(vm, a) * vm_to_number(vm, b);
                    vm.sp -= 2;
                    vpush(vm, num_norm(r));
                }
            }
            case OP_DIV, OP_MOD, OP_POW: {
                if !value_is_primitive(vpeek(vm, 0)) || !value_is_primitive(vpeek(vm, 1)) {
                    if !coerce_top2_prim(vm, HINT_NUMBER) { break case; }
                }
                Value b = vpeek(vm, 0);
                Value a = vpeek(vm, 1);
                if value_is_bigint(a) || value_is_bigint(b) {
                    Value r;
                    ignore try_bigint_op(vm, a, b, op, &r);
                    vm.sp -= 2;
                    if !vm.has_pending { vpush(vm, r); }
                    break case;
                }
                f64 x = vm_to_number(vm, a);
                f64 y = vm_to_number(vm, b);
                f64 r = 0.0;
                if op == OP_DIV { r = x / y; }
                if op == OP_POW { r = pow(x, y); }
                if op == OP_MOD {
                    f64 inf = 1.0e308 * 10.0;
                    if y == 0.0 || x != x || y != y || x == inf || x == -inf {
                        r = 0.0 / 0.0;
                    } else if y == inf || y == -inf {
                        r = x;
                    } else {
                        f64 q = x / y;
                        f64 tq = q < 0.0 ? ceil(q) : floor(q);
                        r = x - tq * y;
                    }
                }
                vm.sp -= 2;
                vpush(vm, num_norm(r));
            }
            case OP_NEG: {
                Value v = vpeek(vm, 0);
                if value_is_bigint(v) {
                    vm.sp--;
                    vpush(vm, bigint_negate(vm, v));
                    break case;
                }
                f64 r = -vm_to_number(vm, v);
                vm.sp--;
                vpush(vm, num_norm(r));
            }
            case OP_TONUM: {
                Value v = vpeek(vm, 0);
                if value_is_bigint(v) { break case; }   // ToNumeric keeps BigInt
                f64 r = vm_to_number(vm, v);
                vm.sp--;
                vpush(vm, num_norm(r));
            }
            case OP_TOSTR: {
                // ToString with the string hint (template substitutions)
                Value s = js_to_string_value(vm, vpeek(vm, 0));
                if !vm.has_pending {
                    vm.sp--;
                    vpush(vm, s);
                }
            }
            case OP_INC, OP_DEC: {
                Value v = vpeek(vm, 0);
                vm.sp--;
                if value_is_bigint(v) {
                    vpush(vm, bigint_step(vm, v, op == OP_INC));
                } else if value_is_int(v) {
                    i64 s = cast(i64, value_as_int(v)) + (op == OP_INC ? 1 : -1);
                    if s >= -2147483648 && s <= 2147483647 { vpush(vm, value_int(cast(i32, s))); }
                    else { vpush(vm, value_number(cast(f64, s))); }
                } else {
                    f64 r = vm_to_number(vm, v) + (op == OP_INC ? 1.0 : -1.0);
                    vpush(vm, num_norm(r));
                }
            }
            case OP_NOT: {
                bool r = !js_truthy(vpeek(vm, 0));
                vm.sp--;
                vpush(vm, value_bool(r));
            }
            case OP_BITNOT: {
                if value_is_bigint(vpeek(vm, 0)) {
                    vm_throw_error(vm, ERR_TYPE, "BigInt bitwise operators are not supported yet");
                    break case;
                }
                i32 r = ~f64_to_i32(vm_to_number(vm, vpeek(vm, 0)));
                vm.sp--;
                vpush(vm, value_int(r));
            }
            case OP_TYPEOF: {
                Value v = vpeek(vm, 0);
                str s = "object";
                if value_is_undefined(v) || value_is_hole(v) { s = "undefined"; }
                else if value_is_number(v) { s = "number"; }
                else if value_is_bool(v) { s = "boolean"; }
                else if value_is_string(v) { s = "string"; }
                else if value_is_symbol(v) { s = "symbol"; }
                else if value_is_bigint(v) { s = "bigint"; }
                else if value_is_function(v) || value_is_native(v) { s = "function"; }
                else if value_is_object(v) && (value_as_object(v).obj_flags & OBJF_PROXY) != 0
                        && value_is_callable(v) { s = "function"; }
                GcString* g = gc_new_string(&vm.heap, s);
                vm.sp--;
                vpush(vm, value_cell(&g.head));
            }
            case OP_EQ, OP_NEQ: {
                // object vs a non-nullish primitive: ToPrimitive the object
                Value a0 = vpeek(vm, 1);
                Value b0 = vpeek(vm, 0);
                bool a_ref = !value_is_primitive(a0);
                bool b_ref = !value_is_primitive(b0);
                bool threw = false;
                if a_ref && !b_ref && !value_is_null(b0) && !value_is_undefined(b0) {
                    Value pa;
                    if vm_to_primitive(vm, a0, HINT_DEFAULT, &pa) {
                        *(vm.stack + vm.sp - 2) = pa;
                    } else { threw = true; }
                } else if b_ref && !a_ref && !value_is_null(a0) && !value_is_undefined(a0) {
                    Value pb;
                    if vm_to_primitive(vm, b0, HINT_DEFAULT, &pb) {
                        *(vm.stack + vm.sp - 1) = pb;
                    } else { threw = true; }
                }
                if threw { break case; }
                bool r = js_loose_eq(vpeek(vm, 1), vpeek(vm, 0));
                if op == OP_NEQ { r = !r; }
                vm.sp -= 2;
                vpush(vm, value_bool(r));
            }
            case OP_SEQ, OP_SNEQ: {
                bool r = js_strict_eq(vpeek(vm, 1), vpeek(vm, 0));
                if op == OP_SNEQ { r = !r; }
                vm.sp -= 2;
                vpush(vm, value_bool(r));
            }
            case OP_LT, OP_GT, OP_LE, OP_GE: {
                if !value_is_primitive(vpeek(vm, 0)) || !value_is_primitive(vpeek(vm, 1)) {
                    if !coerce_top2_prim(vm, HINT_NUMBER) { break case; }
                }
                Value b = vpeek(vm, 0);
                Value a = vpeek(vm, 1);
                bool r = false;
                if value_is_int(a) && value_is_int(b) {
                    i32 x = value_as_int(a);
                    i32 y = value_as_int(b);
                    if op == OP_LT { r = x < y; }
                    if op == OP_GT { r = x > y; }
                    if op == OP_LE { r = x <= y; }
                    if op == OP_GE { r = x >= y; }
                } else if value_is_string(a) && value_is_string(b) {
                    i32 c = js_str_cmp(gc_string_view(value_as_string(a)),
                        gc_string_view(value_as_string(b)));
                    if op == OP_LT { r = c < 0; }
                    if op == OP_GT { r = c > 0; }
                    if op == OP_LE { r = c <= 0; }
                    if op == OP_GE { r = c >= 0; }
                } else if value_is_bigint(a) || value_is_bigint(b) {
                    i32 c = 0;
                    bool unordered = false;
                    if value_is_bigint(a) && value_is_bigint(b) {
                        c = bn_cmp(bigint_view(value_as_bigint(a)), bigint_view(value_as_bigint(b)));
                    } else {
                        f64 x = value_is_bigint(a) ? bn_to_f64(bigint_view(value_as_bigint(a))) : vm_to_number(vm, a);
                        f64 y = value_is_bigint(b) ? bn_to_f64(bigint_view(value_as_bigint(b))) : vm_to_number(vm, b);
                        if x != x || y != y { unordered = true; }
                        else if x < y { c = -1; } else if x > y { c = 1; }
                    }
                    if unordered { r = false; }
                    else if op == OP_LT { r = c < 0; }
                    else if op == OP_GT { r = c > 0; }
                    else if op == OP_LE { r = c <= 0; }
                    else { r = c >= 0; }
                } else {
                    f64 x = vm_to_number(vm, a);
                    f64 y = vm_to_number(vm, b);
                    if op == OP_LT { r = x < y; }
                    if op == OP_GT { r = x > y; }
                    if op == OP_LE { r = x <= y; }
                    if op == OP_GE { r = x >= y; }
                }
                vm.sp -= 2;
                vpush(vm, value_bool(r));
            }
            case OP_BAND, OP_BOR, OP_BXOR, OP_SHL, OP_SHR: {
                if value_is_bigint(vpeek(vm, 0)) || value_is_bigint(vpeek(vm, 1)) {
                    vm_throw_error(vm, ERR_TYPE, "BigInt bitwise operators are not supported yet");
                    break case;
                }
                i32 x = f64_to_i32(vm_to_number(vm, vpeek(vm, 1)));
                i32 y = f64_to_i32(vm_to_number(vm, vpeek(vm, 0)));
                i32 r = 0;
                if op == OP_BAND { r = x & y; }
                if op == OP_BOR { r = x | y; }
                if op == OP_BXOR { r = x ^ y; }
                if op == OP_SHL { r = x << (y & 31); }
                if op == OP_SHR { r = x >> (y & 31); }
                vm.sp -= 2;
                vpush(vm, value_int(r));
            }
            case OP_USHR: {
                if value_is_bigint(vpeek(vm, 0)) || value_is_bigint(vpeek(vm, 1)) {
                    vm_throw_error(vm, ERR_TYPE, "BigInts have no unsigned right shift, use >> instead");
                    break case;
                }
                u32 x = f64_to_i32(vm_to_number(vm, vpeek(vm, 1)));
                u32 y = f64_to_i32(vm_to_number(vm, vpeek(vm, 0)));
                u32 r = x >> (y & 31);
                vm.sp -= 2;
                if r <= 2147483647 {
                    vpush(vm, value_int(cast(i32, r)));
                } else {
                    f64 d = r;
                    vpush(vm, value_number(d));
                }
            }
            case OP_INSTANCEOF: {
                if instanceof_hook(vm) { break case; }
                Value ctor = vpeek(vm, 0);
                Value v = vpeek(vm, 1);
                if !value_is_callable(ctor) {
                    vm_throw_error(vm, ERR_TYPE, "right-hand side of instanceof is not callable");
                } else {
                    Value protov = ensure_prototype(vm, ctor);
                    bool r = false;
                    JsObject* start = null;
                    if value_is_object(v) {
                        start = value_as_object(v).proto;
                    } else if value_is_map(v) {
                        start = value_as_map(v).proto;
                    } else if value_is_generator(v) {
                        start = value_as_generator(v).is_async ? vm.async_generator_proto : vm.generator_proto;
                    } else if value_is_bigint(v) {
                        start = vm.bigint_proto;
                    } else if value_is_function(v) || value_is_native(v) {
                        // a function has a chain too: its [[Prototype]], which
                        // defaults to Function.prototype. Constructors linked
                        // by static inheritance are stepped over, since the
                        // right-hand side is always a .prototype object.
                        Value cur = value_undefined();
                        if value_is_function(v) { cur = value_as_function(v).fproto; }
                        while value_is_function(cur) || value_is_native(cur) {
                            Value nxt = value_undefined();
                            if value_is_function(cur) { nxt = value_as_function(cur).fproto; }
                            cur = nxt;
                        }
                        if value_is_object(cur) { start = value_as_object(cur); }
                        else if !value_is_null(cur) { start = vm.function_proto; }
                    }
                    if value_is_object(protov) {
                        JsObject* proto = value_as_object(protov);
                        while start != null {
                            if start == proto {
                                r = true;
                                break;
                            }
                            start = start.proto;
                        }
                    }
                    vm.sp -= 2;
                    vpush(vm, value_bool(r));
                }
            }
            case OP_IN: {
                Value objv = vpeek(vm, 0);
                Value key = vpeek(vm, 1);
                if value_is_function(objv) || value_is_native(objv) {
                    bool r = fn_has_prop(vm, objv, key_to_atom(vm, key));
                    if !vm.has_pending {
                        vm.sp -= 2;
                        vpush(vm, value_bool(r));
                    }
                } else if !value_is_object(objv) {
                    vm_throw_error(vm, ERR_TYPE, "'in' requires an object");
                } else {
                    JsObject* o = value_as_object(objv);
                    bool r = false;
                    if (o.obj_flags & OBJF_PROXY) != 0 {
                        r = proxy_has(vm, cast(JsProxy*, o), key_to_atom(vm, key));
                    } else {
                        u32 a = key_to_atom(vm, key);
                        // array elements and `length` live outside the property
                        // table; resolve through the atom so a string-form
                        // index ("0" in arr) answers like the numeric one
                        i32 idx = (o.obj_flags & (OBJF_ARRAY | OBJF_TYPEDARRAY)) != 0
                            ? ta_atom_index(vm, a) : -1;
                        if (o.obj_flags & OBJF_ARRAY) != 0 && a == vm.atom_length {
                            r = true;
                        } else if idx >= 0 && (o.obj_flags & OBJF_TYPEDARRAY) != 0 {
                            // a view's elements are bytes, not properties
                            r = idx < ta_prop_int(vm, o, vm.atom_ta_len);
                        } else if idx >= 0 {
                            r = js_array_has(o, idx);
                        } else if (o.obj_flags & OBJF_GLOBAL) != 0 {
                            r = vm_global_exists(vm, a) || js_has_prop(o, a);
                        } else {
                            r = js_has_prop(o, a);
                        }
                    }
                    if vm.has_pending { break case; }
                    vm.sp -= 2;
                    vpush(vm, value_bool(r));
                }
            }
            case OP_HASPRIVATE: {
                // #name in obj: an own/inherited check for the private field's
                // hidden atom, never routed through a proxy trap. Non-object
                // right-hand sides throw, like the ordinary `in` operator.
                u32 a = cast(u32, value_as_int(*(t.consts + rd_u16(code, ip))));
                ip += 2;
                Value objv = vpeek(vm, 0);
                if value_is_function(objv) || value_is_native(objv) {
                    bool r = fn_has_prop(vm, objv, a);
                    if !vm.has_pending {
                        vm.sp--;
                        vpush(vm, value_bool(r));
                    }
                } else if value_is_object(objv) {
                    bool r = js_has_prop(value_as_object(objv), a);
                    vm.sp--;
                    vpush(vm, value_bool(r));
                } else {
                    vm_throw_error(vm, ERR_TYPE, "Cannot use 'in' to search for a private field in a non-object");
                }
            }
            case OP_JUMP: { ip = rd_u16(code, ip); }
            case OP_JUMPF: {
                i32 target = rd_u16(code, ip);
                ip += 2;
                if !js_truthy(vpop(vm)) { ip = target; }
            }
            case OP_JUMPT: {
                i32 target = rd_u16(code, ip);
                ip += 2;
                if js_truthy(vpop(vm)) { ip = target; }
            }
            case OP_JF_KEEP: {
                i32 target = rd_u16(code, ip);
                ip += 2;
                if !js_truthy(vpeek(vm, 0)) { ip = target; } else { vm.sp--; }
            }
            case OP_JT_KEEP: {
                i32 target = rd_u16(code, ip);
                ip += 2;
                if js_truthy(vpeek(vm, 0)) { ip = target; } else { vm.sp--; }
            }
            case OP_JNN_KEEP: {
                i32 target = rd_u16(code, ip);
                ip += 2;
                if !is_nullish(vpeek(vm, 0)) { ip = target; } else { vm.sp--; }
            }
            case OP_CLOSURE: {
                FnTemplate* sub = *(t.subs + rd_u16(code, ip));
                ip += 2;
                JsFunction* f = js_new_function(&vm.heap, sub, sub.n_upvals);
                for i32 i = 0; i < sub.n_upvals; i++ {
                    TmplUpval u = *(sub.upvals + i);
                    if u.from_parent_slot {
                        *(f.upvals + i) = *(vm.stack + fr.base + u.index);
                    } else {
                        *(f.upvals + i) = *(fr.fun.upvals + u.index);
                    }
                }
                vpush(vm, value_cell(&f.head));
            }
            case OP_CALL, OP_NEW, OP_SUPERCALL: {
                i32 argc = rd_u16(code, ip);
                ip += 2;
                fr.cur_ip = ip;   // this frame's call site, for stack traces
                // super() forwards the current frame's new.target to the base
                // constructor; captured now, before fr is reassigned
                Value inherited_target = fr.new_target;
                Value fnv;
                Value thisv;
                if op == OP_NEW {
                    new_instance(vm, argc);
                }
                if !vm.has_pending {
                    fnv = vpeek(vm, argc + 1);
                    thisv = vpeek(vm, argc);
                    if value_is_native(fnv) {
                        JsNative* na = value_as_native(fnv);
                        Value res = na.fun(cast(void*, vm), fnv, thisv, vm.stack + vm.sp - argc, argc);
                        if op == OP_NEW && !value_is_reference(res) { res = thisv; }
                        vm.sp -= argc + 2;
                        vpush(vm, res);
                    } else if value_is_function(fnv) {
                        JsFunction* f = value_as_function(fnv);
                        FnTemplate* ft = f.tmpl;
                        if call_kind_error(vm, ft, op) {
                            // threw: not constructable, or a class called bare
                        } else if ft.is_gen {
                            Value gv = make_generator_from_call(vm, f, argc);
                            if ft.is_async { value_as_generator(gv).is_async = true; }
                            vpush(vm, gv);
                        } else if ft.is_async {
                            Value rp = make_async_from_call(vm, f, argc);
                            vpush(vm, rp);
                        } else if vm.fp >= VM_FRAMES_MAX
                            || vm.sp + ft.n_slots + 8 >= VM_STACK_MAX {
                            vm_throw_error(vm, ERR_RANGE, "maximum call stack size exceeded");
                        } else {
                            i32 arm = gc_root_mark(&vm.heap);
                            Value argobj = value_undefined();
                            if ft.needs_arguments {
                                argobj = vm_build_arguments(vm, vm.stack + vm.sp - argc, argc);
                                gc_root(&vm.heap, argobj);
                            }
                            normalize_args(vm, ft, argc);
                            i32 base = vm.sp - ft.n_params;
                            for i32 i = ft.n_params; i < ft.n_slots; i++ {
                                vpush(vm, value_undefined());
                            }
                            Frame* nf = vm.frames + vm.fp;
                            nf.fun = f;
                            nf.tmpl = ft;
                            nf.ret_ip = ip;
                            nf.cur_ip = 0;
                            nf.base = base;
                            nf.this_val = thisv;
                            nf.arguments_obj = argobj;
                            nf.is_ctor = op == OP_NEW;
                            if op == OP_NEW { nf.new_target = fnv; }
                            else if op == OP_SUPERCALL { nf.new_target = inherited_target; }
                            else { nf.new_target = value_undefined(); }
                            nf.gen = null;
                            vm.fp++;
                            gc_root_reset(&vm.heap, arm);
                            fr = nf;
                            t = ft;
                            code = t.code;
                            ip = 0;
                        }
                    } else if value_is_object(fnv)
                              && (value_as_object(fnv).obj_flags & OBJF_PROXY) != 0 {
                        // a callable-target proxy: route through apply/construct
                        JsProxy* p = cast(JsProxy*, value_as_object(fnv));
                        Value res;
                        if op == OP_NEW {
                            res = proxy_construct(vm, p, vm.stack + vm.sp - argc, argc, fnv);
                        } else {
                            res = proxy_apply(vm, p, thisv, vm.stack + vm.sp - argc, argc);
                        }
                        vm.sp -= argc + 2;
                        if !vm.has_pending { vpush(vm, res); }
                    } else {
                        vm_throw_error(vm, ERR_TYPE, "not a function");
                    }
                }
            }
            case OP_RETURN: {
                Value res = vpop(vm);
                if fr.is_ctor && !value_is_reference(res) { res = fr.this_val; }
                vm.sp = fr.base - 2;
                vpush(vm, res);
                // A return inside a try leaves that try's handler open;
                // drop every handler still belonging to this frame so a
                // later throw doesn't unwind into the dead frame.
                while vm.hp > 0 && (vm.handlers + (vm.hp - 1)).frame_count >= vm.fp {
                    vm.hp--;
                }
                vm.fp--;
                if vm.fp < stop_fp { return 0; }
                Frame* popped = vm.frames + vm.fp;
                fr = vm.frames + (vm.fp - 1);
                t = fr.tmpl;
                code = t.code;
                ip = popped.ret_ip;
            }
            case OP_NEWOBJ: {
                JsObject* o = js_new_object(&vm.heap, vm.object_proto);
                vpush(vm, value_cell(&o.head));
            }
            case OP_NEWARR: {
                i32 n = rd_u16(code, ip);
                ip += 2;
                JsObject* arr = js_new_array(&vm.heap, vm.array_proto);
                for i32 i = 0; i < n; i++ {
                    js_array_set(arr, i, *(vm.stack + vm.sp - n + i));
                }
                vm.sp -= n;
                vpush(vm, value_cell(&arr.head));
            }
            case OP_GETPROP: {
                u32 a = cast(u32, value_as_int(*(t.consts + rd_u16(code, ip))));
                ip += 2;
                Value out;
                if vm_get_prop_value(vm, vpeek(vm, 0), a, &out) {
                    vm.sp--;
                    vpush(vm, out);
                }
            }
            case OP_SETPROP: {
                u32 a = cast(u32, value_as_int(*(t.consts + rd_u16(code, ip))));
                ip += 2;
                Value v = vpeek(vm, 0);
                Value objv = vpeek(vm, 1);
                if set_prop_atom(vm, objv, a, v) {
                    vm.sp -= 2;
                    vpush(vm, v);
                }
            }
            case OP_DEFMETHOD: {
                // like SETPROP but installs a non-enumerable property
                // (class methods, static methods, constructor back-link)
                u32 a = cast(u32, value_as_int(*(t.consts + rd_u16(code, ip))));
                ip += 2;
                Value v = vpeek(vm, 0);
                Value objv = vpeek(vm, 1);
                PropList* props = null;
                if value_is_object(objv) { props = &value_as_object(objv).props; }
                else if value_is_function(objv) { props = &value_as_function(objv).props; }
                else if value_is_native(objv) { props = &value_as_native(objv).props; }
                if props != null {
                    props_set_desc(props, a, v, PROP_WRITABLE | PROP_CONFIGURABLE);
                }
                vm.sp -= 2;
                vpush(vm, v);
            }
            case OP_GETINDEX: {
                Value key = vpeek(vm, 0);
                Value objv = vpeek(vm, 1);
                if value_is_array(objv) {
                    i32 idx = val_to_index(key);
                    if idx >= 0 {
                        Value r = js_array_get(value_as_object(objv), idx);
                        vm.sp -= 2;
                        vpush(vm, r);
                        break case;
                    }
                }
                if vm_is_typed_array(objv) {
                    i32 idx = val_to_index(key);
                    if idx >= 0 {
                        Value r = vm_ta_get(vm, value_as_object(objv), idx);
                        vm.sp -= 2;
                        vpush(vm, r);
                        break case;
                    }
                }
                if value_is_string(objv) {
                    i32 idx = val_to_index(key);
                    if idx >= 0 {
                        GcString* s = value_as_string(objv);
                        if idx < s.u16len {
                            str view = gc_string_view(s);
                            // fast path: ASCII strings index by byte
                            if s.u16len == s.len {
                                str one;
                                one.data = view.data + idx;
                                one.len = 1;
                                GcString* g = gc_new_string(&vm.heap, one);
                                vm.sp -= 2;
                                vpush(vm, value_cell(&g.head));
                            } else {
                                str_buf sb;
                                str_buf_init(&sb);
                                u16_slice_into(&sb, view, idx, idx + 1);
                                GcString* g = gc_new_string(&vm.heap, str_buf_to_str(&sb));
                                str_buf_free(&sb);
                                vm.sp -= 2;
                                vpush(vm, value_cell(&g.head));
                            }
                        } else {
                            vm.sp -= 2;
                            vpush(vm, value_undefined());
                        }
                        break case;
                    }
                }
                u32 a = key_to_atom(vm, key);
                Value out;
                if vm_get_prop_value(vm, objv, a, &out) {
                    vm.sp -= 2;
                    vpush(vm, out);
                }
            }
            case OP_SETINDEX: {
                Value v = vpeek(vm, 0);
                Value key = vpeek(vm, 1);
                Value objv = vpeek(vm, 2);
                if value_is_array(objv) {
                    i32 idx = val_to_index(key);
                    if idx >= 0 {
                        if !array_index_writable(vm, value_as_object(objv), idx) { break case; }
                        js_array_set(value_as_object(objv), idx, v);
                        vm.sp -= 3;
                        vpush(vm, v);
                        break case;
                    }
                }
                if vm_is_typed_array(objv) {
                    i32 idx = val_to_index(key);
                    if idx >= 0 {
                        vm_ta_set(vm, value_as_object(objv), idx, v);
                        vm.sp -= 3;
                        vpush(vm, v);
                        break case;
                    }
                }
                u32 a = key_to_atom(vm, key);
                if set_prop_atom(vm, objv, a, v) {
                    vm.sp -= 3;
                    vpush(vm, v);
                }
            }
            case OP_GETMETHOD: {
                u32 a = cast(u32, value_as_int(*(t.consts + rd_u16(code, ip))));
                ip += 2;
                Value objv = vpeek(vm, 0);
                Value out;
                if vm_get_prop_value(vm, objv, a, &out) {
                    vm.sp--;
                    vpush(vm, out);
                    vpush(vm, objv);
                }
            }
            case OP_GETMETHOD_DYN: {
                Value key = vpeek(vm, 0);
                Value objv = vpeek(vm, 1);
                Value out = value_undefined();
                bool ok = true;
                if value_is_array(objv) {
                    i32 idx = val_to_index(key);
                    if idx >= 0 {
                        out = js_array_get(value_as_object(objv), idx);
                    } else {
                        ok = vm_get_prop_value(vm, objv, key_to_atom(vm, key), &out);
                    }
                } else {
                    ok = vm_get_prop_value(vm, objv, key_to_atom(vm, key), &out);
                }
                if ok {
                    vm.sp -= 2;
                    vpush(vm, out);
                    vpush(vm, objv);
                }
            }
            case OP_DELPROP: {
                u32 a = cast(u32, value_as_int(*(t.consts + rd_u16(code, ip))));
                ip += 2;
                if delete_key(vm, vpeek(vm, 0), a) {
                    vm.sp--;
                    vpush(vm, value_bool(true));
                }
            }
            case OP_DELINDEX: {
                if delete_index(vm, vpeek(vm, 1), vpeek(vm, 0)) {
                    vm.sp -= 2;
                    vpush(vm, value_bool(true));
                }
            }
            case OP_TRY_PUSH: {
                i32 target = rd_u16(code, ip);
                ip += 2;
                if vm.hp >= VM_HANDLERS_MAX {
                    vm_throw_error(vm, ERR_RANGE, "too many nested try blocks");
                } else {
                    Handler* h = vm.handlers + vm.hp;
                    h.frame_count = vm.fp;
                    h.sp = vm.sp;
                    h.ip = target;
                    vm.hp++;
                }
            }
            case OP_TRY_POP: { vm.hp--; }
            case OP_THROW: { vm_throw(vm, vpop(vm)); }
            case OP_SETPROTO: {
                Value protov = vpop(vm);
                Value objv = vpeek(vm, 0);
                if value_is_object(objv) {
                    // only an object or null is a prototype; `{__proto__: 5}`
                    // leaves the object's prototype alone
                    if value_is_object(protov) {
                        value_as_object(objv).proto = value_as_object(protov);
                    } else if value_is_null(protov) {
                        value_as_object(objv).proto = null;
                    }
                } else if value_is_function(objv) {
                    // static inheritance: a derived ctor's [[Prototype]]
                    value_as_function(objv).fproto = protov;
                }
            }
            case OP_DEFPROP: {
                u32 a = cast(u32, value_as_int(*(t.consts + rd_u16(code, ip))));
                ip += 2;
                Value v = vpop(vm);
                Value objv = vpeek(vm, 0);
                if value_is_object(objv) { js_set_prop(value_as_object(objv), a, v); }
            }
            case OP_DEFPROP_DYN: {
                Value v = vpop(vm);
                Value kv = vpeek(vm, 0);
                u32 a = key_to_atom(vm, kv);
                if vm.has_pending { break case; }
                vm.sp--;
                Value objv = vpeek(vm, 0);
                if value_is_object(objv) { js_set_prop(value_as_object(objv), a, v); }
            }
            case OP_DEFGETTER, OP_DEFSETTER: {
                u32 a = cast(u32, value_as_int(*(t.consts + rd_u16(code, ip))));
                ip += 2;
                bool enumer = rd_u16(code, ip) != 0;
                ip += 2;
                def_accessor(vm, vpeek(vm, 1), a, vpeek(vm, 0), op == OP_DEFGETTER, enumer);
                vm.sp--;
            }
            case OP_DEFGETTER_DYN, OP_DEFSETTER_DYN: {
                // computed accessor: `get [expr]() {}` / `set [expr](v) {}`
                bool enumer = rd_u16(code, ip) != 0;
                ip += 2;
                u32 a = key_to_atom(vm, vpeek(vm, 1));
                if vm.has_pending { break case; }
                def_accessor(vm, vpeek(vm, 2), a, vpeek(vm, 0), op == OP_DEFGETTER_DYN, enumer);
                vm.sp -= 2;
            }
            case OP_ARR_APPEND: {
                Value v = vpeek(vm, 0);
                Value arrv = vpeek(vm, 1);
                if value_is_array(arrv) {
                    JsObject* d = value_as_object(arrv);
                    js_array_set(d, d.elen, v);
                }
                vm.sp--;
            }
            case OP_ARR_SPREAD: {
                Value src = vpeek(vm, 0);
                Value arrv = vpeek(vm, 1);
                if value_is_array(arrv) {
                    JsObject* d = value_as_object(arrv);
                    if value_is_array(src) {
                        JsObject* s = value_as_object(src);
                        for i32 i = 0; i < s.elen; i++ {
                            js_array_set(d, d.elen, js_array_get(s, i));
                        }
                    } else if value_is_string(src) {
                        // spread yields code points, not bytes or units
                        str view = gc_string_view(value_as_string(src));
                        i32 off = 0;
                        while off < view.len {
                            i32 n;
                            ignore utf8_decode(view, off, &n);
                            str one;
                            one.data = view.data + off;
                            one.len = n;
                            GcString* g = gc_new_string(&vm.heap, one);
                            js_array_set(d, d.elen, value_cell(&g.head));
                            off += n;
                        }
                    } else {
                        // general iterables via the protocol
                        Value it;
                        if vm_get_iterator(vm, src, &it) {
                            vpush(vm, it);
                            while true {
                                Value val;
                                bool done = false;
                                if !vm_iter_next(vm, vpeek(vm, 0), &val, &done) { break; }
                                if done { break; }
                                vpush(vm, val);
                                js_array_set(d, d.elen, vpeek(vm, 0));
                                vm.sp--;
                            }
                            vm.sp--;
                        }
                    }
                }
                if !vm.has_pending { vm.sp--; }
            }
            case OP_OBJ_SPREAD: {
                Value src = vpeek(vm, 0);
                Value dstv = vpeek(vm, 1);
                if value_is_object(dstv) && value_is_string(src) {
                    spread_string_into(vm, value_as_object(dstv), src);
                } else if value_is_object(dstv) && value_is_object(src) {
                    JsObject* d = value_as_object(dstv);
                    JsObject* s = value_as_object(src);
                    if (s.obj_flags & OBJF_PROXY) != 0 {
                        // spread a proxy through its ownKeys + get traps
                        JsObject* keys = vm_own_keys(vm, src);
                        vpush(vm, value_cell(&keys.head));
                        for i32 i = 0; i < keys.elen; i++ {
                            Value kv = js_array_get(keys, i);
                            u32 pk = key_to_atom(vm, kv);
                            Value pv;
                            ignore vm_get_prop_value(vm, src, pk, &pv);
                            js_set_prop(d, pk, pv);
                        }
                        vm.sp--;
                    } else if (s.obj_flags & OBJF_ARRAY) != 0 {
                        for i32 i = 0; i < s.elen; i++ {
                            string ks = format("{}", i);
                            u32 a2 = atom_intern(&vm.atoms, ks);
                            free(ks);
                            js_set_prop(d, a2, js_array_get(s, i));
                        }
                    } else if (s.obj_flags & OBJF_TYPEDARRAY) != 0 {
                        i32 len = ta_prop_int(vm, s, vm.atom_ta_len);
                        for i32 i = 0; i < len; i++ {
                            string ks = format("{}", i);
                            u32 a2 = atom_intern(&vm.atoms, ks);
                            free(ks);
                            js_set_prop(d, a2, vm_ta_get(vm, s, i));
                        }
                    }
                    vm_props_order(vm, &s.props);
                    for i32 i = 0; i < s.props.len; i++ {
                        Prop* pr = s.props.items + i;
                        if !prop_copyable(vm, pr) { continue; }
                        Value pv = pr.val;
                        if value_is_accessor(pv) {
                            if !vm_get_prop_value(vm, src, pr.key, &pv) { break; }
                        }
                        js_set_prop(d, pr.key, pv);
                    }
                }
                if !vm.has_pending { vm.sp--; }
            }
            case OP_OBJ_REST: {
                Value exv = *(t.consts + rd_u16(code, ip));
                ip += 2;
                Value src = vpeek(vm, 0);
                JsObject* r = js_new_object(&vm.heap, vm.object_proto);
                vpush(vm, value_cell(&r.head));
                if value_is_object(src) && value_is_object(exv) {
                    JsObject* s = value_as_object(src);
                    JsObject* ex = value_as_object(exv);
                    vm_props_order(vm, &s.props);
                    for i32 i = 0; i < s.props.len; i++ {
                        Prop* pr = s.props.items + i;
                        if !prop_copyable(vm, pr) { continue; }
                        bool skip = false;
                        for i32 j = 0; j < ex.elen; j++ {
                            Value kv = js_array_get(ex, j);
                            if value_is_int(kv) && cast(u32, value_as_int(kv)) == pr.key {
                                skip = true;
                                break;
                            }
                        }
                        if skip { continue; }
                        Value pv = pr.val;
                        if value_is_accessor(pv) {
                            if !vm_get_prop_value(vm, src, pr.key, &pv) { break; }
                        }
                        js_set_prop(r, pr.key, pv);
                    }
                }
                if !vm.has_pending {
                    Value rv = vpop(vm);
                    vm.sp--;
                    vpush(vm, rv);
                }
            }
            case OP_ARR_SLICE_FROM: {
                i32 start = rd_u16(code, ip);
                ip += 2;
                Value src = vpeek(vm, 0);
                JsObject* out = js_new_array(&vm.heap, vm.array_proto);
                vpush(vm, value_cell(&out.head));
                i32 n = 0;
                if value_is_array(src) {
                    JsObject* s = value_as_object(src);
                    for i32 i = start; i < s.elen; i++ {
                        js_array_set(out, n, js_array_get(s, i));
                        n++;
                    }
                } else if value_is_string(src) {
                    i32 len = value_as_string(src).len;
                    for i32 i = start; i < len; i++ {
                        str view = gc_string_view(value_as_string(src));
                        str one;
                        one.data = view.data + i;
                        one.len = 1;
                        GcString* g = gc_new_string(&vm.heap, one);
                        js_array_set(out, n, value_cell(&g.head));
                        n++;
                    }
                }
                Value ov = vpop(vm);
                vm.sp--;
                vpush(vm, ov);
            }
            case OP_CALL_ARRAY, OP_NEW_ARRAY, OP_SUPERCALL_ARRAY: {
                fr.cur_ip = ip;   // call site, for stack traces
                // new.target for the frame vm_call_stack is about to build:
                // the constructor for `new`, the inherited target for super()
                if op == OP_NEW_ARRAY { vm.pending_new_target = vpeek(vm, 1); }
                else if op == OP_SUPERCALL_ARRAY { vm.pending_new_target = fr.new_target; }
                if op == OP_NEW_ARRAY {
                    Value fnv2 = vpeek(vm, 1);
                    if !value_is_callable(fnv2) {
                        vm_throw_error(vm, ERR_TYPE, "not a constructor");
                    } else {
                        Value protov = ensure_prototype(vm, fnv2);
                        JsObject* proto = null;
                        if value_is_object(protov) { proto = value_as_object(protov); }
                        JsObject* inst = js_new_object(&vm.heap, proto);
                        // [ctor, arr] -> [ctor, inst, arr]
                        Value arr = vpeek(vm, 0);
                        *(vm.stack + vm.sp - 1) = value_cell(&inst.head);
                        vpush(vm, arr);
                    }
                }
                if !vm.has_pending {
                    Value arrv = vpeek(vm, 0);
                    i32 n = 0;
                    if value_is_array(arrv) { n = value_as_object(arrv).elen; }
                    if vm.sp + n + 8 >= VM_STACK_MAX {
                        vm_throw_error(vm, ERR_RANGE, "maximum call stack size exceeded");
                    } else {
                        JsObject* aobj = value_as_object(arrv);
                        for i32 i = 0; i < n; i++ {
                            vpush(vm, js_array_get(aobj, i));
                        }
                        // drop the array slot beneath the args
                        for i32 i = 0; i < n; i++ {
                            *(vm.stack + vm.sp - n - 1 + i) = *(vm.stack + vm.sp - n + i);
                        }
                        vm.sp--;
                        Value instv = vpeek(vm, n);
                        Value res = vm_call_stack(vm, n);
                        if op == OP_NEW_ARRAY && !value_is_reference(res) { res = instv; }
                        vpush(vm, res);
                    }
                }
            }
            case OP_JUMP_NULLISH: {
                i32 target = rd_u16(code, ip);
                ip += 2;
                if is_nullish(vpeek(vm, 0)) {
                    vm.sp--;
                    ip = target;
                }
            }
            case OP_JUMP_NULLISH_METH: {
                i32 target = rd_u16(code, ip);
                ip += 2;
                if is_nullish(vpeek(vm, 1)) {
                    vm.sp -= 2;
                    ip = target;
                }
            }
            case OP_CHECK_ITERABLE: {
                Value v = vpeek(vm, 0);
                if !value_is_array(v) && !value_is_string(v) {
                    vm_throw_error(vm, ERR_TYPE, "value is not iterable");
                }
            }
            case OP_KEYS: {
                Value src = vpeek(vm, 0);
                JsObject* arr = forin_keys(vm, src);
                vm.sp--;
                vpush(vm, value_cell(&arr.head));
            }
            case OP_YIELD, OP_AWAIT: {
                JsGenerator* g = fr.gen;
                if g == null {
                    vm_throw_error(vm, ERR_TYPE, "yield outside a generator");
                } else {
                    g.awaiting = op == OP_AWAIT;
                    i32 depth = vm.sp - fr.base - 1;
                    if g.saved != null { free(g.saved); }
                    g.saved = alloc<Value>(depth > 0 ? depth : 1);
                    for i32 i = 0; i < depth; i++ {
                        *(g.saved + i) = *(vm.stack + fr.base + i);
                    }
                    g.saved_len = depth;
                    g.resume_ip = ip;
                    i32 nh = 0;
                    while vm.hp - nh > 0 {
                        Handler* h = vm.handlers + (vm.hp - nh - 1);
                        if h.frame_count != vm.fp { break; }
                        nh++;
                    }
                    if g.handler_data != null {
                        free(g.handler_data);
                        g.handler_data = null;
                    }
                    g.n_handlers = nh;
                    if nh > 0 {
                        g.handler_data = alloc<i32>(nh * 2);
                        for i32 i = 0; i < nh; i++ {
                            Handler* h = vm.handlers + (vm.hp - nh + i);
                            *(g.handler_data + i * 2) = h.sp - fr.base;
                            *(g.handler_data + i * 2 + 1) = h.ip;
                        }
                        vm.hp -= nh;
                    }
                    g.state = GEN_SUSPENDED;
                    g.unwind_return = vm.unwind_return;
                    Value out = vpop(vm);
                    vm.sp = fr.base - 2;
                    vpush(vm, out);
                    vm.fp--;
                    if vm.fp < stop_fp { return 0; }
                    Frame* popped = vm.frames + vm.fp;
                    fr = vm.frames + (vm.fp - 1);
                    t = fr.tmpl;
                    code = t.code;
                    ip = popped.ret_ip;
                }
            }
            case OP_GET_ITER: {
                Value v = vpeek(vm, 0);
                Value it;
                if vm_get_iterator(vm, v, &it) {
                    vm.sp--;
                    vpush(vm, it);
                }
            }
            case OP_GET_AITER: {
                do_get_aiter(vm);
            }
            case OP_CATCH_ENTER: {
                catch_enter(vm);
            }
            case OP_ITER_SEND: {
                do_iter_send(vm);
            }
            case OP_ITER_NEXT: {
                Value iter = vpeek(vm, 0);
                Value val;
                bool done = false;
                if vm_iter_next(vm, iter, &val, &done) {
                    vm.sp--;
                    vpush(vm, val);
                    vpush(vm, value_bool(done));
                }
            }
            case OP_ITER_STEP: {
                i32 dslot = rd_u16(code, ip);
                ip += 2;
                iter_step(vm, fr.base + dslot);
            }
            case OP_ITER_REST: {
                i32 dslot = rd_u16(code, ip);
                ip += 2;
                iter_rest(vm, fr.base + dslot);
            }
            case OP_ITER_CLOSE: {
                i32 dslot = rd_u16(code, ip);
                ip += 2;
                iter_close(vm, fr.base + dslot);
            }
            case OP_ITER_CHECK: {
                iter_check_result(vm);
            }
            case OP_FREEZE: {
                freeze_top(vm);
            }
            case OP_REGEX: {
                Value srcv = *(t.consts + rd_u16(code, ip));
                ip += 2;
                Value flgv = *(t.consts + rd_u16(code, ip));
                ip += 2;
                Value re = vm_new_regexp(vm, gc_string_view(value_as_string(srcv)),
                    gc_string_view(value_as_string(flgv)));
                if !vm.has_pending { vpush(vm, re); }
            }
            default: {
                eprint("vm: bad opcode {}\n", op);
                exit(70);
            }
        }

    }
    return 0;
}

// Runs a compiled script template. 0 ok, 1 uncaught exception.
i32 vm_run_template(VM* vm, FnTemplate* t) {
    i32 saved_sp = vm.sp;
    vpush(vm, value_undefined());   // fn slot
    vpush(vm, value_undefined());   // this slot
    i32 base = vm.sp;
    for i32 i = 0; i < t.n_slots; i++ {
        vpush(vm, value_undefined());
    }
    Frame* fr = vm.frames + vm.fp;
    fr.fun = null;
    fr.tmpl = t;
    fr.ret_ip = 0;
    fr.cur_ip = 0;
    fr.base = base;
    fr.this_val = value_undefined();
    fr.arguments_obj = value_undefined();
    fr.is_ctor = false;
    fr.new_target = value_undefined();
    fr.gen = null;
    vm.fp++;
    i32 status = vm_execute(vm, vm.fp);
    if status != 0 {
        Value e = vm.pending;
        vm.has_pending = false;
        vm.pending = value_undefined();
        print_uncaught(vm, e);
    }
    vm.sp = saved_sp;
    vm.hp = 0;
    return status;
}

// Aligns pushed args with the template's slots: fill/trim, or collect
// surplus into the rest array bound to the last parameter.
private void normalize_args(VM* vm, FnTemplate* ft, i32 argc) {
    if ft.has_rest {
        i32 named = ft.n_params - 1;
        i32 extra = argc > named ? argc - named : 0;
        JsObject* rest = js_new_array(&vm.heap, vm.array_proto);
        for i32 i = 0; i < extra; i++ {
            js_array_set(rest, i, *(vm.stack + vm.sp - extra + i));
        }
        vm.sp -= extra;
        i32 have = argc - extra;
        while have < named {
            vpush(vm, value_undefined());
            have++;
        }
        vpush(vm, value_cell(&rest.head));
        return;
    }
    while argc < ft.n_params {
        vpush(vm, value_undefined());
        argc++;
    }
    while argc > ft.n_params {
        vm.sp--;
        argc--;
    }
}

// Own enumerable keys as an array of strings; strings enumerate their
// indices. Result is unrooted — consume before the next allocation.
// for-in visits enumerable string keys along the whole prototype chain, each
// name only once; a shadowing own property hides the inherited one.
private JsObject* forin_keys(VM* vm, Value objv) {
    JsObject* own = vm_own_keys(vm, objv);
    if !value_is_object(objv) { return own; }
    JsObject* proto = value_as_object(objv).proto;
    if proto == null { return own; }
    vpush(vm, value_cell(&own.head));
    JsObject* out = js_new_array(&vm.heap, vm.array_proto);
    vpush(vm, value_cell(&out.head));
    i32 n = 0;
    for i32 i = 0; i < own.elen; i++ {
        js_array_set(out, n, js_array_get(own, i));
        n++;
    }
    JsObject* cur = proto;
    while cur != null {
        JsObject* pk = vm_own_keys(vm, value_cell(&cur.head));
        vpush(vm, value_cell(&pk.head));
        for i32 i = 0; i < pk.elen; i++ {
            Value k = js_array_get(pk, i);
            bool seen = false;
            for i32 j = 0; j < out.elen; j++ {
                if js_strict_eq(js_array_get(out, j), k) { seen = true; break; }
            }
            if !seen {
                js_array_set(out, n, k);
                n++;
            }
        }
        vm.sp--;
        cur = cur.proto;
    }
    vm.sp -= 2;
    return out;
}

JsObject* vm_own_keys(VM* vm, Value objv) {
    if value_is_object(objv) && (value_as_object(objv).obj_flags & OBJF_PROXY) != 0 {
        // route through the ownKeys trap, keeping only string keys (for-in and
        // Object.keys ignore symbols)
        JsObject* raw = proxy_own_keys(vm, cast(JsProxy*, value_as_object(objv)));
        vpush(vm, value_cell(&raw.head));
        JsObject* out = js_new_array(&vm.heap, vm.array_proto);
        vpush(vm, value_cell(&out.head));
        i32 m = 0;
        for i32 i = 0; i < raw.elen; i++ {
            Value k = js_array_get(raw, i);
            if value_is_string(k) { js_array_set(out, m, k); m++; }
        }
        vm.sp -= 2;
        return out;
    }
    JsObject* arr = js_new_array(&vm.heap, vm.array_proto);
    vpush(vm, value_cell(&arr.head));
    i32 n = 0;
    if value_is_object(objv) && (value_as_object(objv).obj_flags & OBJF_ARRAY) != 0 {
        JsObject* o = value_as_object(objv);
        for i32 i = 0; i < o.elen; i++ {
            if !js_array_has(o, i) { continue; }   // holes are not keys
            string s = format("{}", i);
            GcString* g = gc_new_string(&vm.heap, s);
            free(s);
            js_array_set(arr, n, value_cell(&g.head));
            n++;
        }
    } else if value_is_object(objv) && (value_as_object(objv).obj_flags & OBJF_TYPEDARRAY) != 0 {
        // typed arrays enumerate their indices as own keys
        JsObject* o = value_as_object(objv);
        i32 len = ta_prop_int(vm, o, vm.atom_ta_len);
        for i32 i = 0; i < len; i++ {
            string s = format("{}", i);
            GcString* g = gc_new_string(&vm.heap, s);
            free(s);
            js_array_set(arr, n, value_cell(&g.head));
            n++;
        }
    }
    PropList* props = value_props(objv);
    if props != null {
        vm_props_order(vm, props);
        for i32 i = 0; i < props.len; i++ {
            if !prop_enumerable(vm, props.items + i) { continue; }
            u32 pk = (props.items + i).key;
            GcString* g = gc_new_string(&vm.heap, atom_name(&vm.atoms, pk));
            js_array_set(arr, n, value_cell(&g.head));
            n++;
        }
    } else if value_is_string(objv) {
        i32 len = value_as_string(objv).len;
        for i32 i = 0; i < len; i++ {
            string s = format("{}", i);
            GcString* g = gc_new_string(&vm.heap, s);
            free(s);
            js_array_set(arr, n, value_cell(&g.head));
            n++;
        }
    }
    vm.sp--;
    return arr;
}

// A Symbol.hasInstance method on the right-hand side decides `instanceof`, and
// applies to plain objects too, not just callables. Returns false when there is
// none and the ordinary prototype-chain walk should run instead. Kept out of the
// interpreter loop so its locals stay off that frame.
// Takes [value, ctor] off the stack and pushes the boolean result itself, so
// the interpreter loop needs no locals of its own for this path.
private bool instanceof_hook(VM* vm) {
    Value ctor = vpeek(vm, 0);
    if !value_is_object(ctor) && !value_is_function(ctor) && !value_is_native(ctor) {
        return false;
    }
    Value hi;
    if !vm_get_prop_value(vm, ctor, vm.sym_has_instance_id, &hi) { return false; }
    if !value_is_callable(hi) { return false; }
    Value v = vpeek(vm, 1);
    Value r = vm_call_value(vm, hi, ctor, &v, 1);
    vm.sp -= 2;
    vpush(vm, value_bool(js_truthy(r)));
    return true;
}

// An element store blocked by the array's integrity level. Throws and returns
// false when it is; kept out of the interpreter loop for frame size.
private bool array_index_writable(VM* vm, JsObject* a, i32 idx) {
    if (a.obj_flags & OBJF_FROZEN) != 0 {
        vm_throw_error(vm, ERR_TYPE, "cannot assign to read-only property of a frozen array");
        return false;
    }
    if idx >= a.elen && (a.obj_flags & OBJF_NONEXT) != 0 {
        vm_throw_error(vm, ERR_TYPE, "cannot add property to a non-extensible array");
        return false;
    }
    return true;
}

// `delete`, shared by the named and computed forms. Removing an absent
// property succeeds; a non-configurable one is a TypeError under strict mode,
// which is the only mode here. Returns false when it threw.
private bool delete_key(VM* vm, Value objv, u32 a) {
    if !value_is_object(objv) { return true; }
    JsObject* o = value_as_object(objv);
    if (o.obj_flags & OBJF_PROXY) != 0 {
        ignore proxy_delete(vm, cast(JsProxy*, o), a);
        return !vm.has_pending;
    }
    if (o.obj_flags & OBJF_GLOBAL) != 0 {
        // removing the binding, not a copy of it: the bare name stops
        // resolving too
        intmap_remove<Value>(&vm.globals, a);
        return true;
    }
    Prop* pe = props_entry(&o.props, a);
    if pe != null && (pe.flags & PROP_CONFIGURABLE) == 0 {
        vm_throw_error(vm, ERR_TYPE, "cannot delete non-configurable property");
        return false;
    }
    ignore js_delete_prop(o, a);
    return true;
}

// The computed form. An array index clears the slot to a hole rather than
// removing a property, so `1 in a` goes false and the iteration methods skip it.
private bool delete_index(VM* vm, Value objv, Value key) {
    if value_is_array(objv) {
        JsObject* a = value_as_object(objv);
        i32 idx = val_to_index(key);
        if idx >= 0 && idx < a.elen {
            if (a.obj_flags & OBJF_SEALED) != 0 {
                vm_throw_error(vm, ERR_TYPE, "cannot delete from a sealed array");
                return false;
            }
            js_array_set(a, idx, value_hole());
        }
        return true;
    }
    if !value_is_object(objv) { return true; }
    return delete_key(vm, objv, key_to_atom(vm, key));
}

// A return completion is not catchable: hand it straight back to the unwinder,
// which will still run any enclosing finally. Kept out of the loop so its
// temporaries stay off that frame.
private void catch_enter(VM* vm) {
    if !vm.unwind_return { return; }
    vm_throw_return(vm, vpop(vm));
}

// [iter, sent] -> [value, done]. Out of the loop for the same frame reason.
private void do_iter_send(VM* vm) {
    Value sent = vpeek(vm, 0);
    Value iter = vpeek(vm, 1);
    Value val;
    bool done = false;
    if !vm_iter_send(vm, iter, sent, &val, &done) { return; }
    vm.sp -= 2;
    vpush(vm, val);
    vpush(vm, value_bool(done));
}

// Builds the fresh `this` for OP_NEW and splices it in under the arguments. A
// constructor whose prototype chain reaches Array.prototype gets a real array
// exotic object, so a subclassed Array still satisfies Array.isArray and
// serialises as an array.
private void new_instance(VM* vm, i32 argc) {
    Value fnv = vpeek(vm, argc);
    if !value_is_callable(fnv) {
        vm_throw_error(vm, ERR_TYPE, "not a constructor");
        return;
    }
    Value protov = ensure_prototype(vm, fnv);
    JsObject* proto = null;
    if value_is_object(protov) { proto = value_as_object(protov); }
    bool as_array = false;
    JsObject* p = proto;
    while p != null {
        if p == vm.array_proto { as_array = true; break; }
        p = p.proto;
    }
    JsObject* inst;
    if as_array {
        inst = js_new_array(&vm.heap, proto);
    } else {
        inst = js_new_object(&vm.heap, proto);
    }
    for i32 i = vm.sp; i > vm.sp - argc; i-- {
        *(vm.stack + i) = *(vm.stack + i - 1);
    }
    *(vm.stack + vm.sp - argc) = value_cell(&inst.head);
    vm.sp++;
}

// `new` on an arrow, shorthand method, generator or async function is a
// TypeError, and a class constructor is reachable only through `new` or
// super(). Returns true when it threw.
private bool call_kind_error(VM* vm, FnTemplate* ft, i32 op) {
    if op == OP_NEW && ft.not_ctor {
        vm_throw_error(vm, ERR_TYPE, "not a constructor");
        return true;
    }
    if op == OP_CALL && ft.is_class {
        vm_throw_error(vm, ERR_TYPE, "class constructor cannot be invoked without 'new'");
        return true;
    }
    return false;
}

// Likewise kept out of the loop: `for await`'s iterator acquisition.
private void do_get_aiter(VM* vm) {
    Value it;
    if vm_get_async_iterator(vm, vpeek(vm, 0), &it) {
        vm.sp--;
        vpush(vm, it);
    }
}

// --- iterator protocol --------------------------------------------------

// v stays rooted by the caller; false = threw.
// The three array-destructuring steps live outside the interpreter loop: their
// locals would otherwise enlarge its stack frame, and deep native re-entry
// (a callback recursing through a builtin) has only so much room.
// `di` is the absolute stack index of the "exhausted" flag.

private void iter_step(VM* vm, i32 di) {
    Value iter = vpeek(vm, 0);
    if js_truthy(*(vm.stack + di)) {
        // spent: the element sees undefined and the iterator is left alone
        vm.sp--;
        vpush(vm, value_undefined());
        return;
    }
    Value val;
    bool done = false;
    if !vm_iter_next(vm, iter, &val, &done) { return; }
    *(vm.stack + di) = value_bool(done);
    vm.sp--;
    vpush(vm, done ? value_undefined() : val);
}

private void iter_rest(VM* vm, i32 di) {
    Value iter = vpeek(vm, 0);
    JsObject* arr = js_new_array(&vm.heap, vm.array_proto);
    vpush(vm, value_cell(&arr.head));   // rooted while draining
    if !js_truthy(*(vm.stack + di)) {
        while true {
            Value val;
            bool done = false;
            if !vm_iter_next(vm, iter, &val, &done) { break; }
            if done { break; }
            js_array_set(arr, arr.elen, val);
        }
    }
    if vm.has_pending { return; }
    *(vm.stack + di) = value_bool(true);
    Value res = vpop(vm);   // arr
    vm.sp--;                // iter
    vpush(vm, res);
}

// Leaves the result in place; a non-object one means the iterator broke its
// protocol, and accepting it would let `done` read as undefined forever.
// Spreading a primitive string copies its characters as index properties.
// Every other primitive has no own enumerable property and contributes
// nothing, which is why only this one needs unwrapping.
private void spread_string_into(VM* vm, JsObject* d, Value sv) {
    GcString* g = value_as_string(sv);
    str view = gc_string_view(g);
    for i32 i = 0; i < g.u16len; i++ {
        str_buf sb;
        str_buf_init(&sb);
        u16_slice_into(&sb, view, i, i + 1);
        GcString* ch1 = gc_new_string(&vm.heap, str_buf_to_str(&sb));
        str_buf_free(&sb);
        vpush(vm, value_cell(&ch1.head));
        string ks = format("{}", i);
        js_set_prop(d, atom_intern(&vm.atoms, ks), value_cell(&ch1.head));
        free(ks);
        vm.sp--;
    }
}

private void freeze_top(VM* vm) {
    Value v = vpeek(vm, 0);
    if value_is_object(v) {
        JsObject* o = value_as_object(v);
        for i32 i = 0; i < o.props.len; i++ {
            Prop* pr = o.props.items + i;
            pr.flags = pr.flags & cast(u8, ~(PROP_WRITABLE | PROP_CONFIGURABLE));
        }
        o.obj_flags = o.obj_flags | OBJF_NONEXT | OBJF_SEALED | OBJF_FROZEN;
    }
}

private void iter_check_result(VM* vm) {
    if !value_is_object(vpeek(vm, 0)) {
        vm_throw_error(vm, ERR_TYPE, "iterator result is not an object");
    }
}

private void iter_close(VM* vm, i32 di) {
    Value iter = vpeek(vm, 0);
    if !js_truthy(*(vm.stack + di)) {
        Value m;
        if vm_get_prop_value(vm, iter, atom_intern(&vm.atoms, "return"), &m) {
            if value_is_callable(m) {
                Value dummy = value_undefined();
                ignore vm_call_value(vm, m, iter, &dummy, 0);
            }
        }
    }
    if vm.has_pending { return; }
    vm.sp--;
}

bool vm_get_iterator(VM* vm, Value v, Value* out) {
    // null/undefined have no properties to read the iterator method from
    if is_nullish(v) {
        vm_throw_error(vm, ERR_TYPE, "value is not iterable");
        return false;
    }
    Value m;
    if !vm_get_prop_value(vm, v, vm.sym_iterator_id, &m) { return false; }
    if !value_is_callable(m) {
        vm_throw_error(vm, ERR_TYPE, "value is not iterable");
        return false;
    }
    Value dummy = value_undefined();
    *out = vm_call_value(vm, m, v, &dummy, 0);
    return !vm.has_pending;
}

// `for await` prefers Symbol.asyncIterator and falls back to the sync
// Symbol.iterator, whose yielded values the loop awaits individually.
bool vm_get_async_iterator(VM* vm, Value v, Value* out) {
    if is_nullish(v) {
        vm_throw_error(vm, ERR_TYPE, "value is not async iterable");
        return false;
    }
    Value m;
    if !vm_get_prop_value(vm, v, vm.sym_async_iterator_id, &m) { return false; }
    if value_is_callable(m) {
        Value dummy = value_undefined();
        *out = vm_call_value(vm, m, v, &dummy, 0);
        return !vm.has_pending;
    }
    return vm_get_iterator(vm, v, out);
}

// iter stays rooted by the caller; consume outputs before allocating.
bool vm_iter_next(VM* vm, Value iter, Value* val, bool* done) {
    Value dummy = value_undefined();
    return iter_next_impl(vm, iter, &dummy, 0, val, done);
}

// yield* forwards whatever its own resume was sent into the delegate's next().
bool vm_iter_send(VM* vm, Value iter, Value sent, Value* val, bool* done) {
    return iter_next_impl(vm, iter, &sent, 1, val, done);
}

private bool iter_next_impl(VM* vm, Value iter, Value* nargs, i32 nargc, Value* val, bool* done) {
    Value m;
    if !vm_get_prop_value(vm, iter, vm.atom_next, &m) { return false; }
    if !value_is_callable(m) {
        vm_throw_error(vm, ERR_TYPE, "iterator has no next method");
        return false;
    }
    Value r = vm_call_value(vm, m, iter, nargs, nargc);
    if vm.has_pending { return false; }
    // A non-object result has no `done` to read, which would otherwise read as
    // falsy and spin the consuming loop forever.
    if !value_is_object(r) {
        vm_throw_error(vm, ERR_TYPE, "iterator result is not an object");
        return false;
    }
    vpush(vm, r);
    Value dv = value_undefined();
    Value vv = value_undefined();
    if value_is_object(r) {
        Value out;
        if !vm_get_prop_value(vm, r, vm.atom_done, &out) {
            vm.sp--;
            return false;
        }
        dv = out;
        if !vm_get_prop_value(vm, r, vm.atom_value, &out) {
            vm.sp--;
            return false;
        }
        vv = out;
    }
    vm.sp--;
    *val = vv;
    *done = js_truthy(dv);
    return true;
}

// --- generators -----------------------------------------------------------

// Consumes [fn, this, args...] from the stack; returns the generator.
private Value make_generator_from_call(VM* vm, JsFunction* f, i32 argc) {
    FnTemplate* ft = f.tmpl;
    i32 arm = gc_root_mark(&vm.heap);
    Value argobj = value_undefined();
    if ft.needs_arguments {
        argobj = vm_build_arguments(vm, vm.stack + vm.sp - argc, argc);
        gc_root(&vm.heap, argobj);
    }
    normalize_args(vm, ft, argc);
    Value thisv = vpeek(vm, ft.n_params);
    JsGenerator* g = js_new_generator(&vm.heap, f, thisv);
    g.arguments_obj = argobj;
    i32 n = ft.n_slots;
    g.saved = alloc<Value>(n > 0 ? n : 1);
    for i32 i = 0; i < ft.n_params; i++ {
        *(g.saved + i) = *(vm.stack + vm.sp - ft.n_params + i);
    }
    for i32 i = ft.n_params; i < n; i++ {
        *(g.saved + i) = value_undefined();
    }
    g.saved_len = n;
    g.resume_ip = 0;
    vm.sp -= ft.n_params + 2;
    gc_root_reset(&vm.heap, arm);
    return value_cell(&g.head);
}

// Runs the generator to its next suspension or completion. The result
// is the yielded or returned value; g.state distinguishes. A throw
// leaves pending set.
Value vm_gen_resume(VM* vm, JsGenerator* g, Value input, bool is_throw) {
    return vm_gen_resume_mode(vm, g, input, is_throw, false);
}

// is_return closes the generator: it unwinds through the finally blocks and
// comes back as the generator's return value.
Value vm_gen_resume_mode(VM* vm, JsGenerator* g, Value input, bool is_throw, bool is_return) {
    // Closing a delegate runs nested inside the outer generator's own return
    // completion, so this flag has to be saved rather than simply cleared.
    bool saved_unwind_return = vm.unwind_return;
    vm.unwind_return = g.unwind_return;
    defer { vm.unwind_return = saved_unwind_return; }
    if g.state == GEN_RUNNING {
        vm_throw_error(vm, ERR_TYPE, "generator is already running");
        return value_undefined();
    }
    if g.state == GEN_DONE {
        return value_undefined();
    }
    if vm.fp >= VM_FRAMES_MAX || vm.sp + g.saved_len + 8 >= VM_STACK_MAX
        || vm.exec_depth >= VM_EXEC_DEPTH_MAX {
        vm_throw_error(vm, ERR_RANGE, "maximum call stack size exceeded");
        return value_undefined();
    }
    i32 entry_sp = vm.sp;
    vpush(vm, value_undefined());   // fn slot
    vpush(vm, value_undefined());   // this slot
    i32 base = vm.sp;
    for i32 i = 0; i < g.saved_len; i++ {
        vpush(vm, *(g.saved + i));
    }
    for i32 i = 0; i < g.n_handlers; i++ {
        Handler* h = vm.handlers + vm.hp;
        h.frame_count = vm.fp + 1;
        h.sp = base + *(g.handler_data + i * 2);
        h.ip = *(g.handler_data + i * 2 + 1);
        vm.hp++;
    }
    bool from_start = g.state == GEN_START;
    Frame* nf = vm.frames + vm.fp;
    nf.fun = g.fun;
    nf.tmpl = g.fun.tmpl;
    nf.ret_ip = g.resume_ip;
    nf.cur_ip = g.resume_ip;
    nf.base = base;
    nf.this_val = g.this_val;
    nf.arguments_obj = g.arguments_obj;
    nf.is_ctor = false;
    nf.new_target = value_undefined();
    nf.gen = g;
    vm.fp++;
    g.state = GEN_RUNNING;
    if !from_start && !is_throw && !is_return {
        vpush(vm, input);
    }
    if is_throw {
        vm.unwind_return = false;
        vm_throw(vm, input);
    } else if is_return {
        vm_throw_return(vm, input);
    }
    vm.exec_depth++;
    i32 st = vm_execute(vm, vm.fp);
    vm.exec_depth--;
    if st != 0 {
        g.state = GEN_DONE;
        vm.sp = entry_sp;
        // a return completion that ran the finally blocks and reached the top
        // of the generator becomes its return value again
        if vm.unwind_return {
            vm.unwind_return = false;
            vm.has_pending = false;
            Value rv = vm.pending;
            vm.pending = value_undefined();
            return rv;
        }
        return value_undefined();
    }
    Value res = vpop(vm);
    if g.state == GEN_RUNNING { g.state = GEN_DONE; }
    return res;
}

// --- promises ---------------------------------------------------------------

bool vm_is_promise(VM* vm, Value v) {
    if !value_is_object(v) { return false; }
    return props_get(&value_as_object(v).props, vm.atom_pstate) != null;
}

Value vm_promise_new(VM* vm) {
    JsObject* p = js_new_object(&vm.heap, vm.promise_proto);
    vpush(vm, value_cell(&p.head));
    js_set_prop(p, vm.atom_pstate, value_int(0));
    js_set_prop(p, vm.atom_pvalue, value_undefined());
    JsObject* cbs = js_new_array(&vm.heap, null);
    js_set_prop(p, vm.atom_pcbs, value_cell(&cbs.head));
    return vpop(vm);
}

private void vm_enqueue(VM* vm, i32 kind, bool flag, Value a, Value b, Value c) {
    VmJob j;
    j.kind = kind;
    j.flag = flag;
    j.a = a;
    j.b = b;
    j.c = c;
    vec_push(&vm.jobs, j);
}

private Value nat_adopt_ful(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = cast(VM*, vmp);
    JsNative* me = value_as_native(callee);
    vm_promise_settle(vm, me.env0, argc > 0 ? *(args) : value_undefined(), false);
    return value_undefined();
}

private Value nat_adopt_rej(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = cast(VM*, vmp);
    JsNative* me = value_as_native(callee);
    vm_promise_settle(vm, me.env0, argc > 0 ? *(args) : value_undefined(), true);
    return value_undefined();
}

// Drops handled / no-longer-rejected entries from the candidate list, so a
// tight loop of reject-then-handle promises does not grow it unbounded.
private void rejections_compact(VM* vm) {
    i32 w = 0;
    for i32 i = 0; i < vm.rejections.len; i++ {
        Value pv = vec_get(&vm.rejections, i);
        if !vm_is_promise(vm, pv) { continue; }
        JsObject* p = value_as_object(pv);
        Value* hv = props_get(&p.props, vm.atom_phandled);
        if hv != null && value_is_true(*hv) { continue; }
        Value* st = props_get(&p.props, vm.atom_pstate);
        if st == null || value_as_int(*st) != 2 { continue; }
        *(vm.rejections.data + w) = pv;
        w++;
    }
    vm.rejections.len = w;
}

// pv and v stay rooted by the caller.
void vm_promise_settle(VM* vm, Value pv, Value v, bool rejected) {
    if !vm_is_promise(vm, pv) { return; }
    JsObject* p = value_as_object(pv);
    Value* st = props_get(&p.props, vm.atom_pstate);
    if st == null || value_as_int(*st) != 0 { return; }
    // A native promise is assimilated through the same thenable job as any
    // other thenable rather than adopted directly: the job is the tick that
    // makes `resolve(aPromise)` settle one turn later than a plain value, as
    // the specified ordering requires.
    // resolving a promise with itself is a cycle it could never escape, so it
    // rejects rather than waiting on a settlement that cannot arrive
    if !rejected && value_same_bits(v, pv) {
        Value e = vm_make_error(vm, ERR_TYPE, "Chaining cycle detected for promise #<Promise>");
        vpush(vm, e);
        vm_promise_settle(vm, pv, e, true);
        vm.sp--;
        return;
    }
    if !rejected && value_is_object(v) {
        // any object with a callable `then` is assimilated: the call itself
        // happens in a job, so the extra tick matches the specified ordering
        Value thenf;
        if !vm_get_prop_value(vm, v, atom_intern(&vm.atoms, "then"), &thenf) {
            // a throwing `then` getter rejects this promise instead
            Value e = vm.pending;
            vm.has_pending = false;
            vm.pending = value_undefined();
            vpush(vm, e);
            vm_promise_settle(vm, pv, e, true);
            vm.sp--;
            return;
        }
        if value_is_callable(thenf) {
            vm_enqueue(vm, JOB_THENABLE, false, v, pv, value_undefined());
            return;
        }
    }
    js_set_prop(p, vm.atom_pstate, value_int(rejected ? 2 : 1));
    js_set_prop(p, vm.atom_pvalue, v);
    Value* cbsv = props_get(&p.props, vm.atom_pcbs);
    // rejecting with no reactions attached (and never handled) is a
    // candidate unhandled rejection; recorded here, reported after the loop.
    if rejected {
        bool has_cbs = cbsv != null && value_is_array(*cbsv) && value_as_object(*cbsv).elen > 0;
        Value* hv = props_get(&p.props, vm.atom_phandled);
        bool handled = hv != null && value_is_true(*hv);
        if !has_cbs && !handled {
            if vm.rejections.len >= 64 { rejections_compact(vm); }
            vec_push(&vm.rejections, pv);
        }
    }
    if cbsv != null && value_is_array(*cbsv) {
        JsObject* cbs = value_as_object(*cbsv);
        for i32 i = 0; i < cbs.elen; i++ {
            Value triple = js_array_get(cbs, i);
            if !value_is_array(triple) { continue; }
            JsObject* tr = value_as_object(triple);
            vm_enqueue(vm, JOB_REACTION, rejected,
                js_array_get(tr, rejected ? 1 : 0), v, js_array_get(tr, 2));
        }
        js_array_set_length(cbs, 0);
    }
}

// Calls `thenable.then(resolve, reject)` on behalf of the promise `pv`. A throw
// from the call, or from reading `then` again, rejects `pv` instead.
private void run_thenable_job(VM* vm, Value thenv, Value pv) {
    vpush(vm, thenv);
    vpush(vm, pv);
    Value thenf;
    bool got = vm_get_prop_value(vm, thenv, atom_intern(&vm.atoms, "then"), &thenf);
    if got && value_is_callable(thenf) {
        JsNative* onf = js_new_native(&vm.heap, &nat_adopt_ful, "resolve");
        onf.env0 = pv;
        vpush(vm, value_cell(&onf.head));
        JsNative* onr = js_new_native(&vm.heap, &nat_adopt_rej, "reject");
        onr.env0 = pv;
        vpush(vm, value_cell(&onr.head));
        Value[2] a = { vpeek(vm, 1), vpeek(vm, 0) };
        ignore vm_call_value(vm, thenf, thenv, &a[0], 2);
        vm.sp -= 2;
    } else if got {
        // no longer thenable: fulfil with the object itself
        vm_promise_settle(vm, pv, thenv, false);
    }
    if vm.has_pending {
        Value e = vm.pending;
        vm.has_pending = false;
        vm.pending = value_undefined();
        vpush(vm, e);
        vm_promise_settle(vm, pv, e, true);
        vm.sp--;
    }
    vm.sp -= 2;
}

// Registers reactions and returns the derived promise.
Value vm_promise_then(VM* vm, Value pv, Value onf, Value onr) {
    if !vm_is_promise(vm, pv) { return value_undefined(); }
    // attaching any reaction marks the rejection (if any) as handled
    js_set_prop(value_as_object(pv), vm.atom_phandled, value_bool(true));
    vpush(vm, pv);
    vpush(vm, onf);
    vpush(vm, onr);
    Value p2 = vm_promise_new(vm);
    vpush(vm, p2);
    JsObject* p = value_as_object(pv);
    Value* st = props_get(&p.props, vm.atom_pstate);
    i32 s = value_as_int(*st);
    if s == 0 {
        JsObject* tr = js_new_array(&vm.heap, null);
        vpush(vm, value_cell(&tr.head));
        js_array_set(tr, 0, onf);
        js_array_set(tr, 1, onr);
        js_array_set(tr, 2, p2);
        Value* cbsv = props_get(&p.props, vm.atom_pcbs);
        if cbsv != null && value_is_array(*cbsv) {
            JsObject* cbs = value_as_object(*cbsv);
            js_array_set(cbs, cbs.elen, vpeek(vm, 0));
        }
        vm.sp--;
    } else {
        Value* pvv = props_get(&p.props, vm.atom_pvalue);
        vm_enqueue(vm, JOB_REACTION, s == 2, s == 1 ? onf : onr, *pvv, p2);
    }
    vm.sp -= 4;
    return p2;
}

// --- async driver ---------------------------------------------------------------

private Value nat_async_ful(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = cast(VM*, vmp);
    JsNative* me = value_as_native(callee);
    vm_async_step(vm, me.env0, me.env1, argc > 0 ? *(args) : value_undefined(), false);
    return value_undefined();
}

private Value nat_async_rej(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = cast(VM*, vmp);
    JsNative* me = value_as_native(callee);
    vm_async_step(vm, me.env0, me.env1, argc > 0 ? *(args) : value_undefined(), true);
    return value_undefined();
}

// Advances an async body one await at a time; settles rpv at the end.
void vm_async_step(VM* vm, Value genv, Value rpv, Value input, bool is_throw) {
    JsGenerator* g = value_as_generator(genv);
    vpush(vm, genv);
    vpush(vm, rpv);
    vpush(vm, input);
    Value res = vm_gen_resume(vm, g, input, is_throw);
    if vm.has_pending {
        Value e = vm.pending;
        vm.has_pending = false;
        vm.pending = value_undefined();
        vpush(vm, e);
        vm_promise_settle(vm, rpv, e, true);
        vm.sp -= 4;
        return;
    }
    vpush(vm, res);
    if g.state == GEN_DONE {
        vm_promise_settle(vm, rpv, res, false);
        vm.sp -= 4;
        return;
    }
    // `await` on a thenable resolves it: route the value through a promise so
    // the assimilation path runs, rather than resuming with the object itself.
    Value target = res;
    i32 extra = 0;
    if !vm_is_promise(vm, res) && value_is_object(res) {
        Value thenf;
        bool got = vm_get_prop_value(vm, res, atom_intern(&vm.atoms, "then"), &thenf);
        if !got {
            // reading `then` threw: the await observes a rejected value, so the
            // awaiting function's own catch handler still gets a chance at it
            Value e = vm.pending;
            vm.has_pending = false;
            vm.pending = value_undefined();
            vpush(vm, e);
            target = vm_promise_new(vm);
            vpush(vm, target);
            extra = 2;
            vm_promise_settle(vm, target, vpeek(vm, 1), true);
        } else if value_is_callable(thenf) {
            target = vm_promise_new(vm);
            vpush(vm, target);
            extra = 1;
            vm_promise_settle(vm, target, res, false);
        }
    }
    if vm_is_promise(vm, target) {
        JsNative* onf = js_new_native(&vm.heap, &nat_async_ful, "step");
        onf.env0 = genv;
        onf.env1 = rpv;
        vpush(vm, value_cell(&onf.head));
        JsNative* onr = js_new_native(&vm.heap, &nat_async_rej, "step");
        onr.env0 = genv;
        onr.env1 = rpv;
        Value onfv = vpop(vm);
        ignore vm_promise_then(vm, target, onfv, value_cell(&onr.head));
    } else {
        vm_enqueue(vm, JOB_ASYNC_STEP, false, genv, rpv, res);
    }
    vm.sp -= 4 + extra;
}

private Value make_async_from_call(VM* vm, JsFunction* f, i32 argc) {
    Value genv = make_generator_from_call(vm, f, argc);
    vpush(vm, genv);
    Value rp = vm_promise_new(vm);
    vpush(vm, rp);
    vm_async_step(vm, genv, rp, value_undefined(), false);
    vm.sp -= 2;
    return rp;
}

// --- async generators -------------------------------------------------------
//
// An async generator suspends for two reasons and has to tell them apart. An
// await resumes here and the consumer never sees it; a yield settles the
// consumer's promise. That is the one branch this driver adds to
// vm_async_step. The queue is the other half: next() can be called again
// before the last one settles, and a body must not be resumed while it is
// already running.

const i32 AG_NEXT = 0;
const i32 AG_THROW = 1;
const i32 AG_RETURN = 2;

private Value agen_result(VM* vm, Value val, bool done) {
    vpush(vm, val);
    JsObject* r = js_new_object(&vm.heap, vm.object_proto);
    vpush(vm, value_cell(&r.head));
    js_set_prop(r, atom_intern(&vm.atoms, "value"), val);
    js_set_prop(r, atom_intern(&vm.atoms, "done"), value_bool(done));
    Value out = value_cell(&r.head);
    vm.sp -= 2;
    return out;
}

// Three values per request: the promise to settle, the resume input, the kind.
private i32 agen_pending(JsGenerator* g) {
    if !value_is_object(g.queue) { return 0; }
    return value_as_object(g.queue).elen - g.qhead;
}

private Value agen_head(JsGenerator* g, i32 k) {
    return js_array_get(value_as_object(g.queue), g.qhead + k);
}

private void agen_push(VM* vm, JsGenerator* g, Value p, Value input, i32 kind) {
    if !value_is_object(g.queue) {
        JsObject* a = js_new_array(&vm.heap, vm.array_proto);
        g.queue = value_cell(&a.head);
    }
    JsObject* q = value_as_object(g.queue);
    i32 n = q.elen;
    js_array_set(q, n, p);
    js_array_set(q, n + 1, input);
    js_array_set(q, n + 2, value_int(kind));
}

// Settles the head request and drops it. The queue is emptied once it drains
// so a long-lived generator does not grow one.
private void agen_settle(VM* vm, JsGenerator* g, Value v, bool reject, bool done) {
    if agen_pending(g) <= 0 {
        g.draining = false;
        return;
    }
    i32 rm = gc_root_mark(&vm.heap);
    gc_root(&vm.heap, v);
    Value p = agen_head(g, 0);
    gc_root(&vm.heap, p);
    JsObject* q = value_as_object(g.queue);
    g.qhead += 3;
    if g.qhead >= q.elen {
        g.qhead = 0;
        js_array_set_length(q, 0);
    }
    g.draining = false;
    if reject { vm_promise_settle(vm, p, v, true); }
    else { vm_promise_settle(vm, p, agen_result(vm, v, done), false); }
    gc_root_reset(&vm.heap, rm);
}

// Starts the next request when the body is idle.
private void vm_agen_pump(VM* vm, Value genv) {
    JsGenerator* g = value_as_generator(genv);
    while !g.draining && agen_pending(g) > 0 {
        Value input = agen_head(g, 1);
        i32 kind = value_as_int(agen_head(g, 2));
        if g.state == GEN_DONE {
            // Nothing left to resume: throw() rejects, return() and next()
            // report the end.
            if kind == AG_THROW { agen_settle(vm, g, input, true, false); }
            else if kind == AG_RETURN { agen_settle(vm, g, input, false, true); }
            else { agen_settle(vm, g, value_undefined(), false, true); }
        } else {
            g.draining = true;
            vm_agen_step(vm, genv, input, kind == AG_THROW, kind == AG_RETURN);
        }
    }
}

private Value nat_agen_await_ful(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = cast(VM*, vmp);
    JsNative* me = value_as_native(callee);
    vm_agen_step(vm, me.env0, argc > 0 ? *(args) : value_undefined(), false, false);
    vm_agen_pump(vm, me.env0);
    return value_undefined();
}

// A rejected await, and a rejected yielded value, both resume the body with a
// throw at the point it suspended, so the generator's own catch can see it.
private Value nat_agen_throw_in(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = cast(VM*, vmp);
    JsNative* me = value_as_native(callee);
    vm_agen_step(vm, me.env0, argc > 0 ? *(args) : value_undefined(), true, false);
    vm_agen_pump(vm, me.env0);
    return value_undefined();
}

// The body finished and its value was a promise. What that promise resolves
// to is what `done: true` carries.
private Value nat_agen_done_ful(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = cast(VM*, vmp);
    JsNative* me = value_as_native(callee);
    agen_settle(vm, value_as_generator(me.env0), argc > 0 ? *(args) : value_undefined(), false, true);
    vm_agen_pump(vm, me.env0);
    return value_undefined();
}

private Value nat_agen_done_rej(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = cast(VM*, vmp);
    JsNative* me = value_as_native(callee);
    agen_settle(vm, value_as_generator(me.env0), argc > 0 ? *(args) : value_undefined(), true, false);
    vm_agen_pump(vm, me.env0);
    return value_undefined();
}

private Value nat_agen_yield_ful(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = cast(VM*, vmp);
    JsNative* me = value_as_native(callee);
    JsGenerator* g = value_as_generator(me.env0);
    agen_settle(vm, g, argc > 0 ? *(args) : value_undefined(), false, false);
    vm_agen_pump(vm, me.env0);
    return value_undefined();
}

// Runs the body until it suspends or finishes, then decides what the head
// request sees.
private void vm_agen_step(VM* vm, Value genv, Value input, bool is_throw, bool is_return) {
    i32 rm = gc_root_mark(&vm.heap);
    gc_root(&vm.heap, genv);
    gc_root(&vm.heap, input);
    JsGenerator* g = value_as_generator(genv);
    Value res = vm_gen_resume_mode(vm, g, input, is_throw, is_return);
    gc_root(&vm.heap, res);
    if vm.has_pending {
        Value e = vm.pending;
        vm.has_pending = false;
        vm.pending = value_undefined();
        gc_root(&vm.heap, e);
        agen_settle(vm, g, e, true, false);
        gc_root_reset(&vm.heap, rm);
        return;
    }
    if g.state == GEN_DONE {
        // `return p` reports what p resolves to, so an object goes through a
        // promise. A primitive cannot be thenable and settles as it is.
        if !value_is_object(res) {
            agen_settle(vm, g, res, false, true);
            gc_root_reset(&vm.heap, rm);
            return;
        }
        Value dt = vm_promise_new(vm);
        gc_root(&vm.heap, dt);
        vm_promise_settle(vm, dt, res, false);
        JsNative* df = js_new_native(&vm.heap, &nat_agen_done_ful, "step");
        df.env0 = genv;
        gc_root(&vm.heap, value_cell(&df.head));
        JsNative* dr = js_new_native(&vm.heap, &nat_agen_done_rej, "step");
        dr.env0 = genv;
        gc_root(&vm.heap, value_cell(&dr.head));
        ignore vm_promise_then(vm, dt, value_cell(&df.head), value_cell(&dr.head));
        gc_root_reset(&vm.heap, rm);
        return;
    }
    // Suspended. Both reasons wait on the value first: an await by
    // definition, a yield because `yield p` hands the consumer what p
    // resolves to. Settling a fresh promise with it runs the assimilation
    // path, so a thenable is followed.
    Value target = vm_promise_new(vm);
    gc_root(&vm.heap, target);
    vm_promise_settle(vm, target, res, false);
    JsNative* onf = js_new_native(&vm.heap, g.awaiting ? &nat_agen_await_ful : &nat_agen_yield_ful, "step");
    onf.env0 = genv;
    gc_root(&vm.heap, value_cell(&onf.head));
    JsNative* onr = js_new_native(&vm.heap, &nat_agen_throw_in, "step");
    onr.env0 = genv;
    gc_root(&vm.heap, value_cell(&onr.head));
    ignore vm_promise_then(vm, target, value_cell(&onf.head), value_cell(&onr.head));
    gc_root_reset(&vm.heap, rm);
}

// next/throw/return on an async generator: queue the request, return its
// promise, and start the body if it is idle.
Value vm_agen_request(VM* vm, Value genv, Value input, i32 kind) {
    i32 rm = gc_root_mark(&vm.heap);
    gc_root(&vm.heap, genv);
    gc_root(&vm.heap, input);
    Value p = vm_promise_new(vm);
    gc_root(&vm.heap, p);
    agen_push(vm, value_as_generator(genv), p, input, kind);
    vm_agen_pump(vm, genv);
    gc_root_reset(&vm.heap, rm);
    return p;
}

// --- I/O handles -------------------------------------------------------------------
//
// The handle table is the reactor's set of live OS resources. In M31
// nothing registers a handle; the API and its ref-count exist so the loop
// exit condition and GC rooting are in place for the socket work in M32.

// Registers a handle (reffed + alive) and returns its slot index as id.
i32 vm_handle_add(VM* vm, i64 fd, i32 kind, Value owner) {
    IoHandle h;
    h.fd = fd;
    h.kind = kind;
    h.interest = 0;
    h.reffed = true;
    h.alive = true;
    h.owner = owner;
    h.ext = null;
    vec_push(&vm.handles, h);
    return vm.handles.len - 1;
}

void vm_handle_close(VM* vm, i32 idx) {
    if idx >= 0 && idx < vm.handles.len { (vm.handles.data + idx).alive = false; }
}

void vm_handle_ref(VM* vm, i32 idx) {
    if idx >= 0 && idx < vm.handles.len { (vm.handles.data + idx).reffed = true; }
}

void vm_handle_unref(VM* vm, i32 idx) {
    if idx >= 0 && idx < vm.handles.len { (vm.handles.data + idx).reffed = false; }
}

// True while any open handle is still keeping the process alive.
bool vm_handles_alive(VM* vm) {
    for i32 i = 0; i < vm.handles.len; i++ {
        IoHandle* h = vm.handles.data + i;
        if h.alive && h.reffed { return true; }
    }
    return false;
}

// Which readiness a handle waits on (NET_POLLIN / NET_POLLOUT); 0 = none.
void vm_handle_set_interest(VM* vm, i32 idx, i16 events) {
    if idx >= 0 && idx < vm.handles.len { (vm.handles.data + idx).interest = events; }
}

i64 vm_handle_fd(VM* vm, i32 idx) {
    if idx >= 0 && idx < vm.handles.len { return (vm.handles.data + idx).fd; }
    return -1;
}

Value vm_handle_owner(VM* vm, i32 idx) {
    if idx >= 0 && idx < vm.handles.len { return (vm.handles.data + idx).owner; }
    return value_undefined();
}

void vm_handle_set_owner(VM* vm, i32 idx, Value owner) {
    if idx >= 0 && idx < vm.handles.len { (vm.handles.data + idx).owner = owner; }
}

void vm_handle_set_ext(VM* vm, i32 idx, void* ext) {
    if idx >= 0 && idx < vm.handles.len { (vm.handles.data + idx).ext = ext; }
}

void* vm_handle_ext(VM* vm, i32 idx) {
    if idx >= 0 && idx < vm.handles.len { return (vm.handles.data + idx).ext; }
    return null;
}

void vm_set_reactor_hook(VM* vm, ReactorHook h) { vm.reactor_hook = h; }
void vm_set_dynimport_hook(VM* vm, DynImportHook h) { vm.dynimport_hook = h; }
void* vm_esm_loader(VM* vm) { return vm.esm_loader; }
void vm_set_esm_loader(VM* vm, void* p) { vm.esm_loader = p; }
void vm_set_arguments_builder(VM* vm, ArgumentsBuilder b) { vm.arguments_builder = b; }

// Build the arguments object for a call whose template needs it. Args live at
// [argstart, argstart+argc); the result is left GC-reachable by the caller
// storing it in the new frame. Returns undefined if no builder is installed.
Value vm_build_arguments(VM* vm, Value* argstart, i32 argc) {
    if vm.arguments_builder == null { return value_undefined(); }
    return vm.arguments_builder(vm, argstart, argc);
}

// --- timers and the event loop -----------------------------------------------------

// Monotonic clock in milliseconds, the unit timer deadlines are kept in.
private f64 vm_now_ms(VM* vm) { return cast(f64, vm_clock_ns()) / 1000000.0; }

i32 vm_add_timer(VM* vm, Value cbfn, f64 delay) {
    return vm_add_timer_full(vm, cbfn, delay, 0.0, value_undefined());
}

// `period` > 0 makes the timer repeat at that interval; `extra` is an array of
// further arguments for the callback, or undefined.
i32 vm_add_timer_full(VM* vm, Value cbfn, f64 delay, f64 period, Value extra) {
    VmTimer tm;
    tm.id = vm.next_timer_id;
    vm.next_timer_id++;
    tm.alive = true;
    tm.reffed = true;
    // absolute deadline: negative/NaN delays clamp to "due now"
    tm.delay = delay > 0.0 ? delay : 0.0;
    tm.due = vm_now_ms(vm) + tm.delay;
    tm.period = period;
    tm.seq = vm.timer_seq;
    vm.timer_seq++;
    tm.cb = cbfn;
    tm.args = extra;
    vec_push(&vm.timers, tm);
    return tm.id;
}

// Node's ref/unref/refresh, reached through the Timeout object.
bool vm_timer_set_ref(VM* vm, i32 id, bool on) {
    for i32 i = 0; i < vm.timers.len; i++ {
        VmTimer* tm = vm.timers.data + i;
        if tm.id == id && tm.alive { tm.reffed = on; return true; }
    }
    return false;
}

bool vm_timer_has_ref(VM* vm, i32 id) {
    for i32 i = 0; i < vm.timers.len; i++ {
        VmTimer* tm = vm.timers.data + i;
        if tm.id == id { return tm.alive && tm.reffed; }
    }
    return false;
}

void vm_timer_refresh(VM* vm, i32 id) {
    for i32 i = 0; i < vm.timers.len; i++ {
        VmTimer* tm = vm.timers.data + i;
        if tm.id == id && tm.alive { tm.due = vm_now_ms(vm) + tm.delay; }
    }
}

// True while some live timer still holds the loop open.
bool vm_timers_reffed(VM* vm) {
    for i32 i = 0; i < vm.timers.len; i++ {
        VmTimer* tm = vm.timers.data + i;
        if tm.alive && tm.reffed { return true; }
    }
    return false;
}

void vm_clear_timer(VM* vm, i32 id) {
    for i32 i = 0; i < vm.timers.len; i++ {
        VmTimer* tm = vm.timers.data + i;
        if tm.id == id { tm.alive = false; }
    }
}

// The reactor. Drains microtasks, then either fires the earliest due
// timer or waits on the monotonic clock until it comes due — real time,
// not virtual. Stays alive while any timer or ref'd handle remains, and
// returns 1 on an uncaught exception in a job. (M32 replaces the timer-
// only wait with a WSAPoll over the handle set.)
const i64 REACTOR_IDLE_MS = 5;

// Builds a poll set from the pollable handles, waits up to timeout_ms
// (-1 blocks until I/O), and dispatches every ready handle through the
// reactor hook. If nothing is pollable, just sleeps out the deadline.
private void reactor_poll(VM* vm, i64 timeout_ms) {
    i32 npoll = 0;
    for i32 i = 0; i < vm.handles.len; i++ {
        IoHandle* h = vm.handles.data + i;
        if h.alive && h.interest != 0 && h.fd >= 0 { npoll++; }
    }
    if npoll == 0 {
        vm_wait_ms(timeout_ms < 0 ? REACTOR_IDLE_MS : timeout_ms);
        return;
    }
    NetPollFd* pf = alloc<NetPollFd>(npoll);
    i32* hidx = alloc<i32>(npoll);
    i32 k = 0;
    for i32 i = 0; i < vm.handles.len; i++ {
        IoHandle* h = vm.handles.data + i;
        if h.alive && h.interest != 0 && h.fd >= 0 {
            (pf + k).fd = h.fd;
            (pf + k).events = h.interest;
            (pf + k).revents = 0;
            *(hidx + k) = i;
            k++;
        }
    }
    i32 to = timeout_ms < 0 ? -1 : cast(i32, timeout_ms);
    i32 r = net_poll(pf, npoll, to);
    if r > 0 && vm.reactor_hook != null {
        for i32 j = 0; j < npoll; j++ {
            i16 re = (pf + j).revents;
            // dispatch by index; the hook re-reads vm.handles, so a
            // vec_push growing the table mid-loop is safe
            if re != 0 {
                vm.reactor_hook(vm, *(hidx + j), re);
                if vm.has_pending { break; }
            }
        }
    }
    free(pf);
    free(hidx);
}

i32 vm_run_event_loop(VM* vm) {
    while true {
        while vm.job_head < vm.jobs.len {
            VmJob j = vec_get(&vm.jobs, vm.job_head);
            vm.job_head++;
            if j.kind == JOB_REACTION {
                vpush(vm, j.c);
                if value_is_callable(j.a) {
                    Value[1] ca = { j.b };
                    Value r = vm_call_value(vm, j.a, value_undefined(), &ca[0], 1);
                    if vm.has_pending {
                        Value e = vm.pending;
                        vm.has_pending = false;
                        vm.pending = value_undefined();
                        vpush(vm, e);
                        vm_promise_settle(vm, j.c, e, true);
                        vm.sp--;
                    } else {
                        vpush(vm, r);
                        vm_promise_settle(vm, j.c, r, false);
                        vm.sp--;
                    }
                } else {
                    vm_promise_settle(vm, j.c, j.b, j.flag);
                }
                vm.sp--;
            } else if j.kind == JOB_THENABLE {
                run_thenable_job(vm, j.a, j.b);
            } else {
                vm_async_step(vm, j.a, j.b, j.c, j.flag);
            }
            if vm.has_pending {
                Value e = vm.pending;
                vm.has_pending = false;
                vm.pending = value_undefined();
                print_uncaught(vm, e);
                return 1;
            }
        }
        vm.jobs.len = 0;
        vm.job_head = 0;
        // earliest live timer by (deadline, insertion order)
        i32 best = -1;
        for i32 i = 0; i < vm.timers.len; i++ {
            VmTimer* tm = vm.timers.data + i;
            if !tm.alive { continue; }
            if best < 0 {
                best = i;
                continue;
            }
            VmTimer* bt = vm.timers.data + best;
            if tm.due < bt.due || (tm.due == bt.due && tm.seq < bt.seq) { best = i; }
        }
        // An unreffed timer fires if the loop runs, but does not keep it
        // running on its own. Checked before firing, or an unreffed interval
        // would hold the process open forever.
        if !vm_timers_reffed(vm) && !vm_handles_alive(vm) { break; }
        f64 now = vm_now_ms(vm);
        bool timer_due = best >= 0 && (vm.timers.data + best).due <= now;
        if !timer_due {
            // nothing to fire yet — poll the sockets, bounded by the next
            // timer deadline (or block until I/O when only handles remain)
            i64 timeout;
            if best < 0 {
                timeout = -1;
            } else {
                f64 d = (vm.timers.data + best).due - now;
                timeout = d < 1.0 ? 1 : cast(i64, d);
            }
            reactor_poll(vm, timeout);
            if vm.has_pending {
                Value e = vm.pending;
                vm.has_pending = false;
                vm.pending = value_undefined();
                print_uncaught(vm, e);
                return 1;
            }
            continue;
        }
        VmTimer* bt2 = vm.timers.data + best;
        Value cbfn = bt2.cb;
        Value extra = bt2.args;
        // a repeating timer is rearmed before it runs, so clearing it from
        // inside its own callback still takes effect
        if bt2.period > 0.0 { bt2.due = now + bt2.period; }
        else { bt2.alive = false; }
        vpush(vm, cbfn);
        vpush(vm, extra);
        Value dummy = value_undefined();
        if value_is_array(extra) {
            JsObject* ea = value_as_object(extra);
            ignore vm_call_value(vm, cbfn, value_undefined(), ea.elems, ea.elen);
        } else {
            ignore vm_call_value(vm, cbfn, value_undefined(), &dummy, 0);
        }
        vm.sp -= 2;
        if vm.has_pending {
            Value e = vm.pending;
            vm.has_pending = false;
            vm.pending = value_undefined();
            print_uncaught(vm, e);
            return 1;
        }
    }
    vm.timers.len = 0;
    vm.handles.len = 0;
    return 0;
}

// Reports any promise that settled rejected and was never handled (no
// .then/.catch/await ever attached), matching Node's fatal-by-default
// unhandled-rejection behavior. Returns 1 if any were found. Call after
// the event loop has fully drained.
i32 vm_report_unhandled(VM* vm) {
    i32 found = 0;
    for i32 i = 0; i < vm.rejections.len; i++ {
        Value pv = vec_get(&vm.rejections, i);
        if !vm_is_promise(vm, pv) { continue; }
        JsObject* p = value_as_object(pv);
        Value* st = props_get(&p.props, vm.atom_pstate);
        if st == null || value_as_int(*st) != 2 { continue; }
        Value* hv = props_get(&p.props, vm.atom_phandled);
        if hv != null && value_is_true(*hv) { continue; }
        // report once (mark handled so a later drain won't repeat it)
        js_set_prop(p, vm.atom_phandled, value_bool(true));
        Value* rv = props_get(&p.props, vm.atom_pvalue);
        Value reason = rv != null ? *rv : value_undefined();
        if !vm.quiet_errors {
            eprint("Unhandled promise rejection. ");
            print_uncaught(vm, reason);
        }
        found = 1;
    }
    vm.rejections.len = 0;
    return found;
}

// Stack already holds fn, this, args. Pops them; returns the result.
// On throw, pending stays set and undefined comes back.
Value vm_call_stack(VM* vm, i32 argc) {
    i32 entry_sp = vm.sp - argc - 2;
    Value fnv = vpeek(vm, argc + 1);
    Value thisv = vpeek(vm, argc);
    if value_is_native(fnv) {
        JsNative* na = value_as_native(fnv);
        Value res = na.fun(cast(void*, vm), fnv, thisv, vm.stack + vm.sp - argc, argc);
        vm.sp = entry_sp;
        return res;
    }
    if !value_is_function(fnv) {
        vm.sp = entry_sp;
        vm_throw_error(vm, ERR_TYPE, "not a function");
        return value_undefined();
    }
    JsFunction* f = value_as_function(fnv);
    FnTemplate* ft = f.tmpl;
    if ft.is_gen { return make_generator_from_call(vm, f, argc); }
    if ft.is_async { return make_async_from_call(vm, f, argc); }
    if vm.fp >= VM_FRAMES_MAX || vm.sp + ft.n_slots + 8 >= VM_STACK_MAX {
        vm.sp = entry_sp;
        vm_throw_error(vm, ERR_RANGE, "maximum call stack size exceeded");
        return value_undefined();
    }
    i32 arm = gc_root_mark(&vm.heap);
    Value argobj = value_undefined();
    if ft.needs_arguments {
        argobj = vm_build_arguments(vm, vm.stack + vm.sp - argc, argc);
        gc_root(&vm.heap, argobj);
    }
    normalize_args(vm, ft, argc);
    i32 base = vm.sp - ft.n_params;
    for i32 i = ft.n_params; i < ft.n_slots; i++ {
        vpush(vm, value_undefined());
    }
    Frame* nf = vm.frames + vm.fp;
    nf.fun = f;
    nf.tmpl = ft;
    nf.ret_ip = 0;
    nf.cur_ip = 0;
    nf.base = base;
    nf.this_val = thisv;
    nf.arguments_obj = argobj;
    nf.is_ctor = false;
    // a super()/new spread call stashes the new.target here; consume it once
    nf.new_target = vm.pending_new_target;
    vm.pending_new_target = value_undefined();
    nf.gen = null;
    vm.fp++;
    gc_root_reset(&vm.heap, arm);
    // this re-entry runs on the native C stack; guard its depth
    if vm.exec_depth >= VM_EXEC_DEPTH_MAX {
        vm.fp--;
        vm.sp = entry_sp;
        vm_throw_error(vm, ERR_RANGE, "maximum call stack size exceeded");
        return value_undefined();
    }
    vm.exec_depth++;
    i32 st = vm_execute(vm, vm.fp);
    vm.exec_depth--;
    if st != 0 {
        vm.sp = entry_sp;
        return value_undefined();
    }
    return vpop(vm);
}

Value vm_call_value(VM* vm, Value fnv, Value thisv, Value* args, i32 argc) {
    vpush(vm, fnv);
    vpush(vm, thisv);
    for i32 i = 0; i < argc; i++ {
        vpush(vm, *(args + i));
    }
    return vm_call_stack(vm, argc);
}

Value js_number_value(f64 v) {
    return num_norm(v);
}

// Rooting hook for natives: values on the VM stack survive collection.
void vm_push(VM* vm, Value v) {
    vpush(vm, v);
}

void vm_pop(VM* vm) {
    vm.sp--;
}

// Pops one rooting slot and returns v — for `return vm_pop_ret(vm, x);`.
Value vm_pop_ret(VM* vm, Value v) {
    vm.sp--;
    return v;
}

f64 js_string_to_number(str s) {
    return vm_str_to_num(s);
}

// Fresh symbol with a reserved property-key id (high bit set).
Value vm_new_symbol(VM* vm, Value desc) {
    u32 id = 0x80000000 | cast(u32, vm.symbols.len);
    JsSymbol* s = js_new_symbol(&vm.heap, id, desc);
    Value v = value_cell(&s.head);
    vec_push(&vm.symbols, v);
    return v;
}

// A well-known symbol, described by its spec name.
Value vm_new_wellknown_symbol(VM* vm, str name) {
    GcString* d = gc_new_string(&vm.heap, name);
    return vm_new_symbol(vm, value_cell(&d.head));
}

u32 vm_atom(VM* vm, str name) {
    return atom_intern(&vm.atoms, name);
}

JsObject* vm_generator_proto(VM* vm) { return vm.generator_proto; }
JsObject* vm_promise_proto(VM* vm) { return vm.promise_proto; }
u32 vm_sym_iterator_id(VM* vm) { return vm.sym_iterator_id; }
u32 vm_sym_to_primitive_id(VM* vm) { return vm.sym_to_primitive_id; }
u32 vm_sym_async_iterator_id(VM* vm) { return vm.sym_async_iterator_id; }
u32 vm_sym_to_string_tag_id(VM* vm) { return vm.sym_to_string_tag_id; }
u32 vm_sym_has_instance_id(VM* vm) { return vm.sym_has_instance_id; }

// --- regex integration ---------------------------------------------------

// Builds a RegExp object; throws SyntaxError on a bad pattern.
Value vm_new_regexp(VM* vm, str source, str flags) {
    if !regex_flags_valid(flags) {
        vm_throw_error(vm, ERR_SYNTAX, "invalid regular expression flags");
        return value_undefined();
    }
    RegexProg* prog = regex_compile(source, flags);
    if prog == null {
        vm_throw_error(vm, ERR_SYNTAX, "invalid regular expression");
        return value_undefined();
    }
    i32 idx = vm.regexps.len;
    vec_push(&vm.regexps, prog);
    JsObject* re = js_new_object(&vm.heap, vm.regexp_proto);
    vpush(vm, value_cell(&re.head));
    props_set_desc(&re.props, vm.atom_rx, value_int(idx), 0);
    // an empty pattern reports "(?:)" so String(re) stays a valid literal
    GcString* src = gc_new_string(&vm.heap, source.len > 0 ? source : "(?:)");
    props_set_desc(&re.props, vm.atom_source, value_cell(&src.head), 0);
    GcString* flg = gc_new_string(&vm.heap, flags);
    props_set_desc(&re.props, vm.atom_flags, value_cell(&flg.head), 0);
    props_set_desc(&re.props, vm.atom_lastindex, value_int(0), PROP_WRITABLE);
    // The flag set, one property per flag. All non-enumerable, so Object.keys
    // and JSON.stringify see a RegExp as the empty object node reports.
    bool f_i = false;
    bool f_m = false;
    bool f_s = false;
    bool f_u = false;
    bool f_y = false;
    bool f_d = false;
    bool f_v = false;
    for i32 k = 0; k < flags.len; k++ {
        u8 c = *(flags.data + k);
        if c == 'i' { f_i = true; }
        if c == 'm' { f_m = true; }
        if c == 's' { f_s = true; }
        if c == 'u' { f_u = true; }
        if c == 'y' { f_y = true; }
        if c == 'd' { f_d = true; }
        if c == 'v' { f_v = true; }
    }
    props_set_desc(&re.props, atom_intern(&vm.atoms, "global"), value_bool(prog.global), 0);
    props_set_desc(&re.props, atom_intern(&vm.atoms, "ignoreCase"), value_bool(f_i), 0);
    props_set_desc(&re.props, atom_intern(&vm.atoms, "multiline"), value_bool(f_m), 0);
    props_set_desc(&re.props, atom_intern(&vm.atoms, "dotAll"), value_bool(f_s), 0);
    props_set_desc(&re.props, atom_intern(&vm.atoms, "unicode"), value_bool(f_u), 0);
    props_set_desc(&re.props, atom_intern(&vm.atoms, "sticky"), value_bool(f_y), 0);
    props_set_desc(&re.props, atom_intern(&vm.atoms, "hasIndices"), value_bool(f_d), 0);
    props_set_desc(&re.props, atom_intern(&vm.atoms, "unicodeSets"), value_bool(f_v), 0);
    return vpop(vm);
}

bool vm_is_regexp(VM* vm, Value v) {
    if !value_is_object(v) { return false; }
    return props_get(&value_as_object(v).props, vm.atom_rx) != null;
}

RegexProg* vm_regexp_prog(VM* vm, Value re) {
    Value* idx = props_get(&value_as_object(re).props, vm.atom_rx);
    if idx == null { return null; }
    return vec_get(&vm.regexps, value_as_int(*idx));
}

u32 vm_atom_lastindex(VM* vm) { return vm.atom_lastindex; }
u32 vm_atom_index(VM* vm) { return vm.atom_index; }

// --- module support ------------------------------------------------------

AtomTable* vm_atoms(VM* vm) { return &vm.atoms; }

// Registers a compiled template so its constants stay GC roots.
void vm_add_template_root(VM* vm, FnTemplate* t) {
    vec_push(&vm.troots, t);
}

// A module namespace object, permanently rooted for the run.
JsObject* vm_new_namespace(VM* vm) {
    JsObject* o = js_new_object(&vm.heap, null);
    gc_root(&vm.heap, value_cell(&o.head));
    return o;
}

// Runs a module body function with the given args. 0 ok, 1 uncaught.
i32 vm_run_module_fn(VM* vm, FnTemplate* t, Value* args, i32 nargs) {
    JsFunction* f = js_new_function(&vm.heap, t, 0);
    Value r = vm_call_value(vm, value_cell(&f.head), value_undefined(), args, nargs);
    ignore r;
    if vm.has_pending {
        Value e = vm.pending;
        vm.has_pending = false;
        vm.pending = value_undefined();
        print_uncaught(vm, e);
        return 1;
    }
    return 0;
}

JsObject* vm_regexp_proto(VM* vm) { return vm.regexp_proto; }
JsObject* vm_map_proto(VM* vm) { return vm.map_proto; }
JsObject* vm_set_proto(VM* vm) { return vm.set_proto; }
JsObject* vm_weakmap_proto(VM* vm) { return vm.weakmap_proto; }
JsObject* vm_weakset_proto(VM* vm) { return vm.weakset_proto; }
JsObject* vm_date_proto(VM* vm) { return vm.date_proto; }

// Milliseconds since the Unix epoch (UTC). Platform-specific.
when os(windows) {
    private extern "kernel32.dll" void GetSystemTimeAsFileTime(u64* ft);
    f64 vm_now_millis(VM* vm) {
        u64 ft = 0;
        GetSystemTimeAsFileTime(&ft);
        // FILETIME: 100ns ticks since 1601-01-01; epoch delta in ms.
        i64 ticks = cast(i64, ft);
        return cast(f64, ticks) / 10000.0 - 11644473600000.0;
    }
}
else when os(wasm) {
    // The host clock import is the only time source, so it also defines
    // the epoch: a host returning nanoseconds since 1970 makes Date
    // absolute, any other origin makes it relative to that origin.
    f64 vm_now_millis(VM* vm) {
        return cast(f64, qpc()) / 1000000.0;
    }
}
else when os(macos) || os(ios) || os(linux) || os(android) {
    private struct vm_timeval { i64 tv_sec; i64 tv_usec; }
    when os(macos) || os(ios) {
        private extern "libSystem.B.dylib" i32 gettimeofday(vm_timeval* tv, void* tz);
    }
    else when os(android) {
        private extern "libc.so" i32 gettimeofday(vm_timeval* tv, void* tz);
    }
    else {
        private extern "libc.so.6" i32 gettimeofday(vm_timeval* tv, void* tz);
    }
    f64 vm_now_millis(VM* vm) {
        vm_timeval tv;
        tv.tv_sec = 0;
        tv.tv_usec = 0;
        ignore gettimeofday(&tv, null);
        return cast(f64, tv.tv_sec) * 1000.0 + cast(f64, tv.tv_usec) / 1000.0;
    }
}
else {
    // No arm for this target. Add a `when os(...)` arm above rather
    // than letting it fall back to another platform's syscalls.
    tsmc_unsupported_target__add_a_when_os_arm _unsupported_clock;
}

// Full pipeline. 0 ok, 1 uncaught exception, 2 compile errors.
i32 vm_run_source(VM* vm, str src, str src_name) {
    DiagList d;
    diags_init(&d);
    Bump arena;
    bump_init(&arena);
    Parser p;
    parser_init(&p, src, &d, &arena);
    Node* prog = parse_program(&p);
    Lower lw;
    lower_init(&lw, &arena, &d);
    lower_program(&lw, prog);

    i32 status = 2;
    if d.n_errors == 0 {
        i32 rmark = gc_root_mark(&vm.heap);
        Compiler co;
        compiler_init(&co, &d, &vm.heap, &vm.atoms, &arena);
        compiler_set_source(&co, src, src_name);
        FnTemplate* t = compile_program(&co, prog);
        vec_push(&vm.troots, t);
        gc_root_reset(&vm.heap, rmark);
        if d.n_errors == 0 {
            status = vm_run_template(vm, t);
            if status == 0 {
                status = vm_run_event_loop(vm);
            }
            if status == 0 && vm_report_unhandled(vm) != 0 { status = 1; }
        }
    }
    if d.n_errors > 0 {
        if !vm.quiet_errors { diags_print(&d, src_name, src); }
        status = 2;
    }
    lower_destroy(&lw);
    parser_destroy(&p);
    bump_destroy(&arena);
    diags_free(&d);
    return status;
}

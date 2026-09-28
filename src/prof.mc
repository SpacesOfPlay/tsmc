// prof.mc -- the sampling profiler and run counters behind `--prof`.
//
// The interpreter calls prof_step once per bytecode while profiling is on:
// it counts the opcode, charges the op to the function running, and every
// PROF_STRIDE ops reads the clock and charges the time since the last
// reading to that function. Time in natives, system calls and the collector
// lands on the JavaScript function that called for it, which is where a
// reader looks first. The report goes to stderr, so a script's own output
// stays comparable.

import vec;
import str;
import bytecode;
import os_time;
import gc;

const i32 PROF_STRIDE = 1024;

// The hooks in the interpreter and the collector are compiled in only for a
// profiling build (`build --prof`, which defines TSMC_PROF); a default build
// has no trace of them. PROF_ON says which kind of build this is.
when defined(TSMC_PROF) { const bool PROF_ON = true; }
else { const bool PROF_ON = false; }

struct Prof {
    i64 ops;
    i64 js_calls;
    i64 native_calls;
    i64[256] hist;
    i32 budget;
    u64 last_ns;
    u64 start_ns;
    Vec<TmplPtr> seen;
    Vec<string> files;   // each seen template's file name, owned: the
                         // template borrows its own from a module that may
                         // be gone by the time of the report
}

Prof* prof_new() {
    Prof* p = new(Prof);
    p.ops = 0;
    p.js_calls = 0;
    p.native_calls = 0;
    for i32 i = 0; i < 256; i++ { p.hist[i] = 0; }
    p.budget = PROF_STRIDE;
    p.start_ns = vm_clock_ns();
    p.last_ns = p.start_ns;
    p.seen = vec_new<TmplPtr>(64);
    p.files = vec_new<string>(64);
    gc_stat_on = true;
    return p;
}

void prof_step(Prof* p, FnTemplate* t, i32 op) {
    p.ops++;
    if op >= 0 && op < 256 { p.hist[op]++; }
    if t.prof_ops == 0 {
        vec_push(&p.seen, t);
        vec_push(&p.files, format("{}", t.src_name.len > 0 ? t.src_name : "<anonymous>"));
    }
    t.prof_ops++;
    p.budget--;
    if p.budget <= 0 {
        p.budget = PROF_STRIDE;
        u64 now = vm_clock_ns();
        t.prof_ns += cast(i64, now - p.last_ns);
        t.prof_samples++;
        p.last_ns = now;
    }
}

str op_name(i32 op) {
    switch op {
        case 0: { return "CONST"; }
        case 1: { return "UNDEF"; }
        case 2: { return "NULL"; }
        case 3: { return "TRUE"; }
        case 4: { return "FALSE"; }
        case 5: { return "HOLE"; }
        case 6: { return "POP"; }
        case 7: { return "DUP"; }
        case 8: { return "DUP2"; }
        case 9: { return "THIS"; }
        case 10: { return "ARGUMENTS"; }
        case 11: { return "CURFUNC"; }
        case 12: { return "NEWTARGET"; }
        case 13: { return "SUPERCALL"; }
        case 14: { return "DYNIMPORT"; }
        case 15: { return "GETLOCAL"; }
        case 16: { return "SETLOCAL"; }
        case 17: { return "INCLOCAL"; }
        case 18: { return "DECLOCAL"; }
        case 19: { return "GETLOCAL_CHK"; }
        case 20: { return "SETHOLE"; }
        case 21: { return "NEWCELL_UNDEF"; }
        case 22: { return "NEWCELL_HOLE"; }
        case 23: { return "CELLIFY"; }
        case 24: { return "GETCELL"; }
        case 25: { return "SETCELL"; }
        case 26: { return "GETCELL_CHK"; }
        case 27: { return "GETUPVAL"; }
        case 28: { return "SETUPVAL"; }
        case 29: { return "GETUPVAL_CHK"; }
        case 30: { return "GETGLOBAL"; }
        case 31: { return "GETGLOBAL_SOFT"; }
        case 32: { return "SETGLOBAL"; }
        case 33: { return "SETEXPORT"; }
        case 34: { return "DELGLOBAL"; }
        case 35: { return "WITH_OBJ"; }
        case 36: { return "WITH_HAS"; }
        case 37: { return "WITH_GET"; }
        case 38: { return "WITH_SET"; }
        case 39: { return "WITH_METH"; }
        case 40: { return "SETCONST_ERR"; }
        case 41: { return "ADD"; }
        case 42: { return "SUB"; }
        case 43: { return "MUL"; }
        case 44: { return "DIV"; }
        case 45: { return "MOD"; }
        case 46: { return "POW"; }
        case 47: { return "NEG"; }
        case 48: { return "TONUM"; }
        case 49: { return "TONUMBER"; }
        case 50: { return "TOSTR"; }
        case 51: { return "TOPROPKEY"; }
        case 52: { return "INC"; }
        case 53: { return "DEC"; }
        case 54: { return "NOT"; }
        case 55: { return "BITNOT"; }
        case 56: { return "TYPEOF"; }
        case 57: { return "EQ"; }
        case 58: { return "NEQ"; }
        case 59: { return "SEQ"; }
        case 60: { return "SNEQ"; }
        case 61: { return "LT"; }
        case 62: { return "GT"; }
        case 63: { return "LE"; }
        case 64: { return "GE"; }
        case 65: { return "BAND"; }
        case 66: { return "BOR"; }
        case 67: { return "BXOR"; }
        case 68: { return "SHL"; }
        case 69: { return "SHR"; }
        case 70: { return "USHR"; }
        case 71: { return "INSTANCEOF"; }
        case 72: { return "IN"; }
        case 73: { return "HASPRIVATE"; }
        case 74: { return "GEN_START"; }
        case 75: { return "YIELD_DELEGATE"; }
        case 76: { return "GETPRIVATE"; }
        case 77: { return "SETPRIVATE"; }
        case 78: { return "GETMETHOD_PRIV"; }
        case 79: { return "JUMP"; }
        case 80: { return "JUMPF"; }
        case 81: { return "LT_JF"; }
        case 82: { return "GT_JF"; }
        case 83: { return "LE_JF"; }
        case 84: { return "GE_JF"; }
        case 85: { return "JUMPT"; }
        case 86: { return "JF_KEEP"; }
        case 87: { return "JT_KEEP"; }
        case 88: { return "JNN_KEEP"; }
        case 89: { return "CLOSURE"; }
        case 90: { return "CALL"; }
        case 91: { return "NEW"; }
        case 92: { return "RETURN"; }
        case 93: { return "NEWOBJ"; }
        case 94: { return "NEWARR"; }
        case 95: { return "GETPROP"; }
        case 96: { return "GETIMPORT"; }
        case 97: { return "SETPROP"; }
        case 98: { return "DEFMETHOD"; }
        case 99: { return "DEFPROP_FIXED"; }
        case 100: { return "DEFMETHOD_DYN"; }
        case 101: { return "GETINDEX"; }
        case 102: { return "SETINDEX"; }
        case 103: { return "GETMETHOD"; }
        case 104: { return "GETMETHOD_DYN"; }
        case 105: { return "DELPROP"; }
        case 106: { return "DELINDEX"; }
        case 107: { return "TRY_PUSH"; }
        case 108: { return "TRY_POP"; }
        case 109: { return "CATCH_ENTER"; }
        case 110: { return "THROW"; }
        case 111: { return "SETPROTO"; }
        case 112: { return "DEFPROP"; }
        case 113: { return "DEFPROP_NEW"; }
        case 114: { return "DEFPROP_DYN"; }
        case 115: { return "DEFGETTER"; }
        case 116: { return "DEFSETTER"; }
        case 117: { return "DEFGETTER_DYN"; }
        case 118: { return "DEFPRIVATE"; }
        case 119: { return "DEFSETTER_DYN"; }
        case 120: { return "ARR_APPEND"; }
        case 121: { return "ARR_SPREAD"; }
        case 122: { return "OBJ_SPREAD"; }
        case 123: { return "OBJ_REST"; }
        case 124: { return "ARR_SLICE_FROM"; }
        case 125: { return "CALL_ARRAY"; }
        case 126: { return "NEW_ARRAY"; }
        case 127: { return "SUPERCALL_ARRAY"; }
        case 128: { return "JUMP_NULLISH"; }
        case 129: { return "JUMP_NULLISH_METH"; }
        case 130: { return "CHECK_ITERABLE"; }
        case 131: { return "KEYS"; }
        case 132: { return "YIELD"; }
        case 133: { return "AWAIT"; }
        case 134: { return "GET_ITER"; }
        case 135: { return "GET_AITER"; }
        case 136: { return "GET_AITER_W"; }
        case 137: { return "REQUIRE_OBJ"; }
        case 138: { return "ITER_CLOSE_ABRUPT"; }
        case 139: { return "RETHROW"; }
        case 140: { return "ITER_SEND"; }
        case 141: { return "ITER_NEXT"; }
        case 142: { return "ITER_STEP"; }
        case 143: { return "ITER_REST"; }
        case 144: { return "ITER_CLOSE"; }
        case 145: { return "ITER_CHECK"; }
        case 146: { return "FREEZE"; }
        case 147: { return "REGEX"; }
    }
    return "?";
}

private str gc_kind_name(i32 k) {
    if k == 0 { return "string"; }
    if k == 1 { return "array"; }
    if k == 2 { return "object"; }
    if k == 3 { return "function"; }
    if k == 4 { return "native"; }
    if k == 5 { return "box"; }
    if k == 6 { return "accessor"; }
    if k == 7 { return "symbol"; }
    if k == 8 { return "generator"; }
    if k == 9 { return "map"; }
    if k == 10 { return "bigint"; }
    if k == 11 { return "bytes"; }
    return "other";
}

private string with_commas(i64 v) {
    string raw = format("{}", v);
    str_buf out;
    str_buf_init(&out);
    i32 n = raw.len;
    for i32 i = 0; i < n; i++ {
        if i > 0 && ((n - i) % 3) == 0 { str_buf_add_byte(&out, ','); }
        str_buf_add_byte(&out, *(raw.data + i));
    }
    free(raw);
    string r = format("{}", str_buf_to_str(&out));
    str_buf_free(&out);
    return r;
}

private string pct(i64 part, i64 whole) {
    if whole <= 0 { return format("0.0"); }
    i64 tenths = (part * 1000 + whole / 2) / whole;
    return format("{}.{}", tenths / 10, tenths % 10);
}

private void pad_to(str_buf* sb, i32 col) {
    while sb.len < col { str_buf_add_byte(sb, ' '); }
}

// Ends the run's accounting and prints it: totals, the functions by time,
// the opcode mix, the allocations by kind.
void prof_report(Prof* p, i64 collections) {
    u64 end = vm_clock_ns();
    i64 wall_ns = cast(i64, end - p.start_ns);
    i64 wall_ms = wall_ns / 1000000;
    i64 kops_s = wall_ns > 0 ? p.ops * 1000000 / wall_ns : 0;
    i64 allocs = 0;
    for i32 k = 0; k < 16; k++ { allocs = allocs + gc_stat_allocs[k]; }
    string s_ops = with_commas(p.ops);
    string s_js = with_commas(p.js_calls);
    string s_nat = with_commas(p.native_calls);
    string s_al = with_commas(allocs);
    eprint("\n--- tsmc --prof: {} ms, {} ops ({} kops/s), {} JS calls, {} native calls, {} allocations, {} collections\n",
        wall_ms, s_ops, kops_s, s_js, s_nat, s_al, collections);
    free(s_ops); free(s_js); free(s_nat); free(s_al);

    // the functions, by time charged: an index sorted over them, so the
    // file names stay where they are
    i64 total_ns = 0;
    i32 n = p.seen.len;
    for i32 i = 0; i < n; i++ { total_ns = total_ns + vec_get(&p.seen, i).prof_ns; }
    i32* idx = alloc<i32>(n > 0 ? n : 1);
    for i32 i = 0; i < n; i++ { *(idx + i) = i; }
    for i32 i = 1; i < n; i++ {
        i32 key = *(idx + i);
        i64 kns = vec_get(&p.seen, key).prof_ns;
        i32 j = i - 1;
        while j >= 0 && vec_get(&p.seen, *(idx + j)).prof_ns < kns {
            *(idx + j + 1) = *(idx + j);
            j--;
        }
        *(idx + j + 1) = key;
    }
    eprint("  time%   ms   ops%  function (file:line)\n");
    i32 shown = n < 30 ? n : 30;
    for i32 i = 0; i < shown; i++ {
        i32 at = *(idx + i);
        FnTemplate* t = vec_get(&p.seen, at);
        if t.prof_ns == 0 && t.prof_ops < p.ops / 1000 { continue; }
        // the function's first recorded position is where it starts
        i32 line = t.n_pos > 0 ? (t.pos + 0).line : 0;
        str_buf sb;
        str_buf_init(&sb);
        string a = pct(t.prof_ns, total_ns);
        pad_to(&sb, 6 - a.len); str_buf_add(&sb, a); free(a);
        string ms = format("{}", t.prof_ns / 1000000);
        pad_to(&sb, 11 - ms.len); str_buf_add(&sb, ms); free(ms);
        string b = pct(t.prof_ops, p.ops);
        pad_to(&sb, 17 - b.len); str_buf_add(&sb, b); free(b);
        str_buf_add(&sb, "  ");
        if t.name.len > 0 { str_buf_add(&sb, t.name); } else { str_buf_add(&sb, "<anonymous>"); }
        str_buf_add(&sb, " (");
        // the file by its last path component
        string* file = p.files.data + at;
        i32 cut = 0;
        for i32 k = 0; k < file.len; k++ {
            u8 c = *(file.data + k);
            if c == '/' || c == 92 { cut = k + 1; }
        }
        str tail;
        tail.data = file.data + cut;
        tail.len = file.len - cut;
        str_buf_add(&sb, tail);
        string ls = format(":{})", line);
        str_buf_add(&sb, ls);
        free(ls);
        eprint("{}\n", str_buf_to_str(&sb));
        str_buf_free(&sb);
    }
    free(idx);

    // the opcode mix
    eprint("  opcodes:");
    i32[256] order;
    for i32 i = 0; i < 256; i++ { order[i] = i; }
    for i32 i = 1; i < 256; i++ {
        i32 key = order[i];
        i32 j = i - 1;
        while j >= 0 && p.hist[order[j]] < p.hist[key] { order[j + 1] = order[j]; j--; }
        order[j + 1] = key;
    }
    for i32 i = 0; i < 16; i++ {
        i32 op = order[i];
        if p.hist[op] == 0 { break; }
        string c = pct(p.hist[op], p.ops);
        eprint(" {} {}%", op_name(op), c);
        free(c);
    }
    eprint("\n");

    // the allocations
    eprint("  allocations:");
    for i32 k = 0; k < 16; k++ {
        if gc_stat_allocs[k] == 0 { continue; }
        string c = with_commas(gc_stat_allocs[k]);
        eprint(" {} {}", gc_kind_name(k), c);
        free(c);
    }
    eprint("\n");
}

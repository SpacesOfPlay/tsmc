// The code cache: a script's templates written out after a run and read
// back before the next one, so a page a browser returns to is not
// parsed and compiled again (doc/DESIGN_bytecode.md, "The code cache").
//
// The file is the template tree of one script as it stood when written:
// a compiled template's code, constants, positions, upvalue spec and the
// property caches' state, a still-lazy template's span and captured
// names. The constants that are atoms are written as their names and
// interned again on load, since atom numbers are per run; a string is
// its bytes, a bigint its digits, anything else its bits. The property
// caches are kept as they were, warm: an own or prototype slot is guarded
// by the key at the slot, an absent entry is written without its
// prototype and epoch and so misses once and re-learns in place. The
// file names the source it was made from by length and hash, and the
// compiler's options that shape the code; a mismatch is a miss.

import vec;
import str;
import value;
import gc;
import atom;
import object;
import bigint;
import bytecode;


const u32 CC_MAGIC = 0x43435354;   // "TSCC"
const u32 CC_VERSION = 1;

const u8 CC_COMPILED = 0;
const u8 CC_LAZY = 1;

const u8 CC_RAW = 0;      // a value that is not a cell: its bits
const u8 CC_ATOM = 1;     // a name: interned again on load
const u8 CC_STRING = 2;
const u8 CC_BIGINT = 3;

// the format's version, with the opcode set folded in so that a new
// instruction makes every earlier file a miss
u32 cc_format() {
    return CC_VERSION * 1024 + cast(u32, cast(i32, OP_RSETINDEX) + 1);
}

u64 cc_hash(str s) {
    u64 h = 14695981039346656037;
    for i32 i = 0; i < s.len; i++ { h = (h ^ cast(u64, *(s.data + i))) * 1099511628211; }
    return h;
}

// --- the writer ---------------------------------------------------------

struct CcOut {
    u8* data;
    i32 len;
    i32 cap;
}

private void cc_reserve(CcOut* o, i32 n) {
    if o.len + n <= o.cap { return; }
    i32 ncap = o.cap == 0 ? 4096 : o.cap;
    while ncap < o.len + n { ncap *= 2; }
    u8* nd = alloc<u8>(ncap);
    if o.len > 0 { memcpy(nd, o.data, o.len); }
    if o.data != null { free(o.data); }
    o.data = nd;
    o.cap = ncap;
}

private void cc_u8(CcOut* o, i32 v) { cc_reserve(o, 1); *(o.data + o.len) = cast(u8, v); o.len++; }
private void cc_u32(CcOut* o, u32 v) {
    cc_reserve(o, 4);
    *(o.data + o.len) = cast(u8, v);
    *(o.data + o.len + 1) = cast(u8, v >> 8);
    *(o.data + o.len + 2) = cast(u8, v >> 16);
    *(o.data + o.len + 3) = cast(u8, v >> 24);
    o.len += 4;
}
private void cc_i32(CcOut* o, i32 v) { cc_u32(o, cast(u32, v)); }
private void cc_u64(CcOut* o, u64 v) { cc_u32(o, cast(u32, v)); cc_u32(o, cast(u32, v >> 32)); }
private void cc_bytes(CcOut* o, u8* p, i32 n) {
    cc_reserve(o, n);
    if n > 0 { memcpy(o.data + o.len, p, n); }
    o.len += n;
}
private void cc_str(CcOut* o, str s) { cc_i32(o, s.len); cc_bytes(o, s.data, s.len); }

private bool cc_const_is_atom(FnTemplate* t, i32 i) {
    return t.catom != null && (*(t.catom + (i >> 3)) & (1 << (i & 7))) != 0;
}

private void cc_write_template(CcOut* o, AtomTable* atoms, FnTemplate* t) {
    cc_u8(o, t.lazy != null ? CC_LAZY : CC_COMPILED);
    cc_str(o, t.name);
    cc_i32(o, t.n_params);
    cc_i32(o, t.arity);
    cc_i32(o, t.n_slots);
    u32 flags = 0;
    if t.has_rest { flags |= 1; }
    if t.is_gen { flags |= 2; }
    if t.is_async { flags |= 4; }
    if t.is_class { flags |= 8; }
    if t.derived_ctor { flags |= 16; }
    if t.not_ctor { flags |= 32; }
    if t.needs_arguments { flags |= 64; }
    if t.sloppy { flags |= 128; }
    cc_u8(o, cast(i32, flags));
    cc_i32(o, t.src_start);
    cc_i32(o, t.src_end);
    cc_i32(o, t.n_upvals);
    for i32 i = 0; i < t.n_upvals; i++ {
        TmplUpval* u = t.upvals + i;
        cc_u8(o, u.from_parent_slot ? 1 : 0);
        cc_i32(o, u.index);
        cc_u8(o, u.by_value ? 1 : 0);
    }
    if t.lazy != null {
        LazyFn* lz = t.lazy;
        cc_i32(o, lz.start);
        cc_u8(o, lz.strict ? 1 : 0);
        cc_u8(o, lz.self_name ? 1 : 0);
        cc_u8(o, lz.method ? 1 : 0);
        cc_u8(o, lz.name_inferred ? 1 : 0);
        cc_i32(o, lz.n_ups);
        for i32 i = 0; i < lz.n_ups; i++ {
            LazyUp* u = lz.ups + i;
            cc_str(o, u.name);
            cc_u8(o, u.is_const ? 1 : 0);
            cc_u8(o, u.tdz ? 1 : 0);
            cc_u8(o, u.exported ? 1 : 0);
            cc_u8(o, u.by_value ? 1 : 0);
        }
        return;
    }
    cc_i32(o, t.code_len);
    cc_bytes(o, t.code, t.code_len);
    cc_i32(o, t.n_consts);
    for i32 i = 0; i < t.n_consts; i++ {
        Value v = *(t.consts + i);
        if cc_const_is_atom(t, i) {
            cc_u8(o, CC_ATOM);
            cc_str(o, atom_name(atoms, cast(u32, value_as_int(v))));
        } else if value_is_string(v) {
            GcString* gs = value_as_string(v);
            cc_u8(o, CC_STRING);
            cc_str(o, str_from(gs.data, gs.len));
        } else if value_is_bigint(v) {
            using string digits = bn_to_str(bigint_view(value_as_bigint(v)));
            cc_u8(o, CC_BIGINT);
            cc_str(o, str_from(digits.data, digits.len));
        } else {
            cc_u8(o, CC_RAW);
            cc_u64(o, v.bits);
        }
    }
    cc_i32(o, t.n_pos);
    for i32 i = 0; i < t.n_pos; i++ {
        PosEntry* p = t.pos + i;
        cc_i32(o, p.code_off);
        cc_i32(o, p.line);
        cc_i32(o, p.col);
    }
    cc_i32(o, t.n_ic_aux);
    for i32 i = 0; i < t.n_ic_aux; i++ {
        IcAux* e = t.ic_aux + i;
        cc_i32(o, e.kind);
        cc_i32(o, e.code_a);
        cc_i32(o, e.code_b);
    }
    cc_i32(o, t.n_subs);
    for i32 i = 0; i < t.n_subs; i++ { cc_write_template(o, atoms, *(t.subs + i)); }
}

// The tree under `root`, compiled from `src` with the options given, as
// one buffer the caller frees.
CcOut codecache_write(AtomTable* atoms, FnTemplate* root, str src, bool lazy, bool script_globals) {
    CcOut o = CcOut{};
    cc_u32(&o, CC_MAGIC);
    cc_u32(&o, cc_format());
    u32 opts = 0;
    if lazy { opts |= 1; }
    if script_globals { opts |= 2; }
    cc_u32(&o, opts);
    cc_i32(&o, src.len);
    cc_u64(&o, cc_hash(src));
    cc_write_template(&o, atoms, root);
    return o;
}

// --- the reader ---------------------------------------------------------

struct CcIn {
    u8* data;
    i32 len;
    i32 at;
    bool bad;           // ran past the end or read what cannot be: the whole load fails
    GcHeap* heap;
    AtomTable* atoms;
    str src;            // the embedder's text, which compiled templates view
    str src_name;
    LazySource* source; // made for the first lazy template, shared by all
    i32 n_templates;
}

private bool cc_need(CcIn* r, i32 n) {
    if r.bad || r.at + n > r.len { r.bad = true; return false; }
    return true;
}
private u8 cc_rd_u8(CcIn* r) {
    if !cc_need(r, 1) { return 0; }
    u8 v = *(r.data + r.at);
    r.at++;
    return v;
}
private u32 cc_rd_u32(CcIn* r) {
    if !cc_need(r, 4) { return 0; }
    u8* p = r.data + r.at;
    r.at += 4;
    return cast(u32, *p) | (cast(u32, *(p + 1)) << 8) | (cast(u32, *(p + 2)) << 16) | (cast(u32, *(p + 3)) << 24);
}
private i32 cc_rd_i32(CcIn* r) { return cast(i32, cc_rd_u32(r)); }
private u64 cc_rd_u64(CcIn* r) {
    u64 lo = cc_rd_u32(r);
    u64 hi = cc_rd_u32(r);
    return lo | (hi << 32);
}
// a count that must be sane for what follows: non-negative and no more
// than the bytes left could hold
private i32 cc_rd_count(CcIn* r, i32 unit) {
    i32 n = cc_rd_i32(r);
    if n < 0 || cast(i64, n) * unit > cast(i64, r.len - r.at) { r.bad = true; return 0; }
    return n;
}
// a view into the buffer, which the caller copies
private str cc_rd_str(CcIn* r) {
    str s;
    s.len = cc_rd_count(r, 1);
    s.data = r.data + r.at;
    r.at += s.len;
    return s;
}

private LazySource* cc_source(CcIn* r) {
    if r.source == null { r.source = lazy_source_new(r.src, r.src_name); }
    return r.source;
}

private FnTemplate* cc_read_template(CcIn* r) {
    if r.bad { return null; }
    u8 state = cc_rd_u8(r);
    str name = cc_rd_str(r);
    i32 n_params = cc_rd_i32(r);
    i32 arity = cc_rd_i32(r);
    i32 n_slots = cc_rd_i32(r);
    u32 flags = cc_rd_u8(r);
    i32 src_start = cc_rd_i32(r);
    i32 src_end = cc_rd_i32(r);
    if r.bad || (state != CC_COMPILED && state != CC_LAZY) { r.bad = true; return null; }
    FnTemplate* t = template_new(name, n_params, n_slots);
    r.n_templates++;
    t.arity = arity;
    t.has_rest = (flags & 1) != 0;
    t.is_gen = (flags & 2) != 0;
    t.is_async = (flags & 4) != 0;
    t.is_class = (flags & 8) != 0;
    t.derived_ctor = (flags & 16) != 0;
    t.not_ctor = (flags & 32) != 0;
    t.needs_arguments = (flags & 64) != 0;
    t.sloppy = (flags & 128) != 0;
    t.src_start = src_start;
    t.src_end = src_end;
    t.n_upvals = cc_rd_count(r, 6);
    if t.n_upvals > 0 {
        t.upvals = alloc<TmplUpval>(t.n_upvals);
        for i32 i = 0; i < t.n_upvals; i++ {
            TmplUpval* u = t.upvals + i;
            u.from_parent_slot = cc_rd_u8(r) != 0;
            u.index = cc_rd_i32(r);
            u.by_value = cc_rd_u8(r) != 0;
        }
    }
    if state == CC_LAZY {
        LazyFn* lz = new(LazyFn);
        lz.source = cc_source(r);
        lz.start = cc_rd_i32(r);
        lz.strict = cc_rd_u8(r) != 0;
        lz.self_name = cc_rd_u8(r) != 0;
        lz.method = cc_rd_u8(r) != 0;
        lz.name_inferred = cc_rd_u8(r) != 0;
        lz.n_ups = cc_rd_count(r, 8);
        if lz.n_ups > 0 {
            lz.ups = alloc<LazyUp>(lz.n_ups);
            // the names' lengths first, for the one block they share
            i32 mark = r.at;
            i32 names_len = 0;
            for i32 i = 0; i < lz.n_ups; i++ {
                str nm = cc_rd_str(r);
                names_len += nm.len;
                r.at += 4;
            }
            r.at = mark;
            lz.names_buf = alloc<u8>(names_len > 0 ? names_len : 1);
            i32 at = 0;
            for i32 i = 0; i < lz.n_ups; i++ {
                LazyUp* u = lz.ups + i;
                str nm = cc_rd_str(r);
                if !r.bad { memcpy(lz.names_buf + at, nm.data, nm.len); }
                u.name.data = lz.names_buf + at;
                u.name.len = nm.len;
                at += nm.len;
                u.is_const = cc_rd_u8(r) != 0;
                u.tdz = cc_rd_u8(r) != 0;
                u.exported = cc_rd_u8(r) != 0;
                u.by_value = cc_rd_u8(r) != 0;
            }
        }
        t.lazy = lz;
        t.owner = lz.source;
        t.owner.refs++;
        t.src_name = lz.source.src_name;
        t.src_text = lz.source.src;
        if lz.start < 0 || lz.start > r.src.len { r.bad = true; }
        return t;
    }
    t.src_name = r.src_name;
    t.src_text = r.src;
    t.code_len = cc_rd_count(r, 1);
    free(t.code);
    t.code = alloc<u8>(t.code_len + 1);
    if !r.bad { memcpy(t.code, r.data + r.at, t.code_len); }
    r.at += t.code_len;
    t.n_consts = cc_rd_count(r, 1);
    if t.n_consts > 0 {
        t.consts = alloc<Value>(t.n_consts);
        for i32 i = 0; i < t.n_consts; i++ { *(t.consts + i) = value_undefined(); }
        i32 nb = (t.n_consts + 7) / 8;
        t.catom = alloc<u8>(nb);
        for i32 i = 0; i < nb; i++ { *(t.catom + i) = 0; }
        for i32 i = 0; i < t.n_consts; i++ {
            u8 tag = cc_rd_u8(r);
            if tag == CC_RAW {
                Value v;
                v.bits = cc_rd_u64(r);
                if value_is_cell(v) { r.bad = true; return t; }
                *(t.consts + i) = v;
            } else if tag == CC_ATOM {
                str nm = cc_rd_str(r);
                if r.bad { return t; }
                *(t.consts + i) = value_int(cast(i32, atom_intern(r.atoms, nm)));
                *(t.catom + (i >> 3)) |= cast(u8, 1 << (i & 7));
            } else if tag == CC_STRING {
                str s = cc_rd_str(r);
                if r.bad { return t; }
                GcString* gs = gc_new_string(r.heap, s);
                Value v = value_cell(&gs.head);
                gc_root(r.heap, v);   // until the VM owns the tree
                *(t.consts + i) = v;
            } else if tag == CC_BIGINT {
                str s = cc_rd_str(r);
                if r.bad { return t; }
                bool ok;
                BigNum bn = bn_from_str(s, &ok);
                if !ok { r.bad = true; return t; }
                GcBigInt* g = js_new_bigint(r.heap, bn);
                bn_free(&bn);
                Value v = value_cell(&g.head);
                gc_root(r.heap, v);
                *(t.consts + i) = v;
            } else {
                r.bad = true;
                return t;
            }
        }
    }
    t.n_pos = cc_rd_count(r, 12);
    if t.n_pos > 0 {
        t.pos = alloc<PosEntry>(t.n_pos);
        for i32 i = 0; i < t.n_pos; i++ {
            PosEntry* p = t.pos + i;
            p.code_off = cc_rd_i32(r);
            p.line = cc_rd_i32(r);
            p.col = cc_rd_i32(r);
        }
    }
    t.n_ic_aux = cc_rd_count(r, 12);
    if t.n_ic_aux > 0 {
        t.ic_aux_cap = t.n_ic_aux;
        t.ic_aux = alloc<IcAux>(t.n_ic_aux);
        for i32 i = 0; i < t.n_ic_aux; i++ {
            IcAux* e = t.ic_aux + i;
            e.kind = cc_rd_i32(r);
            e.code_a = cc_rd_i32(r);
            e.code_b = cc_rd_i32(r);
            e.proto = 0;
            e.epoch = 0;
        }
    }
    t.n_subs = cc_rd_count(r, 1);
    if t.n_subs > 0 {
        t.subs = cast(FnTemplate**, alloc(cast(i64, t.n_subs) * 8));
        for i32 i = 0; i < t.n_subs; i++ { *(t.subs + i) = null; }
        for i32 i = 0; i < t.n_subs; i++ {
            *(t.subs + i) = cc_read_template(r);
            if r.bad { return t; }
        }
    }
    return t;
}

// --- one template, for the lazy functions compiled ahead ----------------

// A compiled template with its subs as a buffer of its own, for an
// embedder's thread that compiles a script's lazy functions ahead of
// their first call (vm.mc, AheadCompile): the VM reads it into the lazy
// template with codecache_read_lazy. The caller frees it.
CcOut codecache_write_one(AtomTable* atoms, FnTemplate* t) {
    CcOut o = CcOut{};
    cc_u32(&o, CC_MAGIC);
    cc_u32(&o, cc_format());
    cc_write_template(&o, atoms, t);
    return o;
}

// The lazy template `t` filled from bytes codecache_write_one made of the
// same function compiled elsewhere, as compile_lazy would fill it; false,
// with `t` as it was, when the bytes are not that. The string constants
// are rooted; the caller resets the root mark once the VM owns them.
bool codecache_read_lazy(GcHeap* heap, AtomTable* atoms, u8* data, i32 len, FnTemplate* t) {
    LazyFn* lz = t.lazy;
    CcIn r = CcIn{};
    r.data = data;
    r.len = len;
    if cc_rd_u32(&r) != CC_MAGIC || cc_rd_u32(&r) != cc_format() { return false; }
    r.heap = heap;
    r.atoms = atoms;
    r.src = lz.source.src;
    r.src_name = lz.source.src_name;
    r.source = lz.source;   // the lazy functions inside it share the source
    FnTemplate* nt = cc_read_template(&r);
    if r.bad || r.at != r.len || nt.lazy != null || nt.n_upvals != t.n_upvals || nt.src_start != t.src_start {
        cc_discard(nt);
        return false;
    }
    t.n_params = nt.n_params;
    t.n_slots = nt.n_slots;
    t.has_rest = nt.has_rest;
    t.needs_arguments = nt.needs_arguments;
    t.sloppy = nt.sloppy;
    free(t.code);
    t.code = nt.code;
    t.code_len = nt.code_len;
    t.consts = nt.consts;
    t.n_consts = nt.n_consts;
    t.catom = nt.catom;
    t.subs = nt.subs;
    t.n_subs = nt.n_subs;
    t.pos = nt.pos;
    t.n_pos = nt.n_pos;
    if nt.upvals != null { free(nt.upvals); }
    if nt.name.data != null { free(nt.name.data); }
    free(nt);
    lazy_free(lz);
    t.lazy = null;
    return true;
}

// a tree the reader left half-made: every template allocated so far,
// through the sub pointers that are set
private void cc_discard(FnTemplate* t) {
    if t == null { return; }
    for i32 i = 0; i < t.n_subs; i++ { cc_discard(*(t.subs + i)); }
    t.n_subs = 0;
    template_free(t);
}

// Whether the bytes are a cache of `src` under these options, before
// anything is built from them.
bool codecache_matches(u8* data, i32 len, str src, bool lazy, bool script_globals) {
    CcIn r = CcIn{};
    r.data = data;
    r.len = len;
    if cc_rd_u32(&r) != CC_MAGIC || cc_rd_u32(&r) != cc_format() { return false; }
    u32 opts = cc_rd_u32(&r);
    u32 want = (lazy ? 1 : 0) + (script_globals ? 2 : 0);
    if opts != want { return false; }
    if cc_rd_i32(&r) != src.len || cc_rd_u64(&r) != cc_hash(src) { return false; }
    return !r.bad;
}

// The tree read back: its root, or null when the bytes are not a cache of
// `src` under these options or are damaged. The string constants are
// rooted; the caller resets the root mark once the VM owns the tree.
// `n_out` counts the templates made.
FnTemplate* codecache_read(GcHeap* heap, AtomTable* atoms, u8* data, i32 len, str src, str src_name,
        bool lazy, bool script_globals, i32* n_out) {
    if !codecache_matches(data, len, src, lazy, script_globals) { return null; }
    CcIn r = CcIn{};
    r.data = data;
    r.len = len;
    r.at = 4 + 4 + 4 + 4 + 8;
    r.heap = heap;
    r.atoms = atoms;
    r.src = src;
    r.src_name = src_name;
    FnTemplate* root = cc_read_template(&r);
    if r.bad || r.at != r.len {
        cc_discard(root);
        if r.source != null && r.source.refs == 0 { lazy_source_free(r.source); }
        return null;
    }
    if r.source != null { root.owner = r.source; r.source.refs++; }
    *n_out = r.n_templates;
    return root;
}

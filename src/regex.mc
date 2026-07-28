// regex.mc — backtracking regular-expression engine.
//
// pattern -> node tree -> instruction array -> recursive backtracking
// matcher. Byte-oriented, ASCII case folding. Standalone: no VM
// dependency. See doc/DESIGN_regex.md.

import vec;
import str;
import "regex_uniprops_data.mc";

// --- node tree ------------------------------------------------------------

enum RxNodeKind {
    RN_EMPTY,
    RN_CHAR,       // a: byte
    RN_ANY,
    RN_CLASS,      // cls index
    RN_CONCAT,     // kids
    RN_ALT,        // kids
    RN_STAR,       // child, a: greedy
    RN_PLUS,
    RN_QUEST,
    RN_REPEAT,     // child, a: min, b: max (-1 unbounded), greedy flag in c
    RN_GROUP,      // child, a: group index
    RN_NCGROUP,    // child
    RN_LOOK,       // child, a: negate (lookahead)
    RN_LOOKBEHIND, // child, a: negate (lookbehind)
    RN_BACKREF,    // a: group index
    RN_BOL, RN_EOL, RN_WORDB, RN_NWORDB
}

struct RxRange { i32 lo; i32 hi; }

struct RxClass {
    RxRange* ranges;
    i32 n;
    bool negate;
}

struct RxNode {
    i32 kind;
    i32 a;
    i32 b;
    i32 c;
    i32 cls;
    RxNode* child;
    RxNode** kids;
    i32 nkids;
}

type RxNodePtr = RxNode*;

// --- instructions ---------------------------------------------------------

enum RxOp {
    I_CHAR, I_ANY, I_CLASS, I_MATCH, I_JMP, I_SPLIT, I_SAVE,
    I_BOL, I_EOL, I_WORDB, I_NWORDB, I_BACKREF, I_LOOK_BEGIN, I_LOOK_DONE,
    I_BEHIND_BEGIN, I_BEHIND_DONE
}

struct RxInst {
    i32 op;
    i32 x;
    i32 y;
    i32 cls;
}

struct RegexProg {
    RxInst* code;
    i32 code_len;
    RxRange* class_ranges;   // all classes' ranges, packed
    i32* class_off;          // per-class start offset into class_ranges
    i32* class_len;
    bool* class_neg;
    i32 n_classes;
    i32 n_groups;            // capturing groups (excludes whole match)
    str* group_names;        // index 1..n_groups -> name (empty if unnamed)
    bool has_named;
    bool ignore_case;
    bool multiline;
    bool dotall;
    bool unicode;
    bool global;
    bool sticky;
}

// --- parser ---------------------------------------------------------------

struct RxGroupName {
    i32 idx;
    str name;
}

struct RxParser {
    str src;
    i32 pos;
    i32 group_count;
    bool failed;
    bool unicode;           // the /u flag: code-point mode
    Vec<RxClass> classes;   // owns range arrays until moved into prog
    Vec<RxGroupName> gnames;
    // \k<name> nodes awaiting resolution: the group may be declared later
    Vec<RxNodePtr> kpend;
    // every (?<name>) in the pattern, collected up front so a \k<...>
    // naming no group can stay a literal escape
    Vec<str> declared;
}

private u8 px_at(RxParser* p, i32 i) {
    if i >= p.src.len { return 0; }
    return *(p.src.data + i);
}

private u8 px_cur(RxParser* p) { return px_at(p, p.pos); }

private RxNode* rx_node(i32 kind) {
    RxNode* n = new(RxNode);
    n.kind = kind;
    return n;
}

private RxNode* rx_kids(i32 kind, Vec<RxNodePtr>* items, i32 base_i) {
    RxNode* n = rx_node(kind);
    n.nkids = items.len - base_i;
    n.kids = cast(RxNode**, alloc(cast(i64, n.nkids) * 8));
    for i32 i = 0; i < n.nkids; i++ {
        *(n.kids + i) = vec_get(items, base_i + i);
    }
    items.len = base_i;
    return n;
}

// Encodes a code point as one atom: a single RN_CHAR for ASCII, else an
// RN_CONCAT of its UTF-8 bytes (so a quantifier applies to the whole
// sequence). Matches the WTF-8 storage of strings.
private RxNode* cp_to_node(i32 cp) {
    u8[4] b;
    i32 n = 0;
    if cp <= 0x7F {
        b[0] = cast(u8, cp);
        n = 1;
    } else if cp <= 0x7FF {
        b[0] = cast(u8, 0xC0 | (cp >> 6));
        b[1] = cast(u8, 0x80 | (cp & 0x3F));
        n = 2;
    } else if cp <= 0xFFFF {
        b[0] = cast(u8, 0xE0 | (cp >> 12));
        b[1] = cast(u8, 0x80 | ((cp >> 6) & 0x3F));
        b[2] = cast(u8, 0x80 | (cp & 0x3F));
        n = 3;
    } else {
        b[0] = cast(u8, 0xF0 | (cp >> 18));
        b[1] = cast(u8, 0x80 | ((cp >> 12) & 0x3F));
        b[2] = cast(u8, 0x80 | ((cp >> 6) & 0x3F));
        b[3] = cast(u8, 0x80 | (cp & 0x3F));
        n = 4;
    }
    if n == 1 {
        RxNode* nd = rx_node(RN_CHAR);
        nd.a = b[0];
        return nd;
    }
    RxNode* cc = rx_node(RN_CONCAT);
    cc.nkids = n;
    cc.kids = cast(RxNode**, alloc(cast(i64, n) * 8));
    for i32 i = 0; i < n; i++ {
        RxNode* ch = rx_node(RN_CHAR);
        ch.a = b[i];
        *(cc.kids + i) = ch;
    }
    return cc;
}

// Length in bytes of the UTF-8 sequence whose lead byte is c (1 for
// ASCII / continuation / invalid).
private i32 utf8_seq_len(u8 c) {
    if c < 0x80 { return 1; }
    if (c & 0xE0) == 0xC0 { return 2; }
    if (c & 0xF0) == 0xE0 { return 3; }
    if (c & 0xF8) == 0xF0 { return 4; }
    return 1;
}

// Reads the code point at p.pos and advances. In u mode a multi-byte
// UTF-8 lead consumes the whole sequence, and a WTF-8 surrogate pair
// (how astral chars appear in pattern source) folds to one astral code
// point; otherwise a single byte.
private i32 px_read_cp(RxParser* p) {
    u8 c = px_cur(p);
    if p.unicode && c >= 0x80 {
        i32 sl = utf8_seq_len(c);
        i32 cp = c;
        if sl == 2 { cp = ((c & 0x1F) << 6) | (px_at(p, p.pos + 1) & 0x3F); }
        else if sl == 3 { cp = ((c & 0x0F) << 12) | ((px_at(p, p.pos + 1) & 0x3F) << 6) | (px_at(p, p.pos + 2) & 0x3F); }
        else if sl == 4 { cp = ((c & 0x07) << 18) | ((px_at(p, p.pos + 1) & 0x3F) << 12) | ((px_at(p, p.pos + 2) & 0x3F) << 6) | (px_at(p, p.pos + 3) & 0x3F); }
        p.pos += sl;
        // fold a high/low WTF-8 surrogate pair into an astral code point
        if cp >= 0xD800 && cp <= 0xDBFF {
            u8 d = px_cur(p);
            if (d & 0xF0) == 0xE0 {
                i32 lo = ((d & 0x0F) << 12) | ((px_at(p, p.pos + 1) & 0x3F) << 6) | (px_at(p, p.pos + 2) & 0x3F);
                if lo >= 0xDC00 && lo <= 0xDFFF {
                    p.pos += 3;
                    cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                }
            }
        }
        return cp;
    }
    p.pos++;
    return c;
}

private void class_add(Vec<RxRange>* rs, i32 lo, i32 hi) {
    RxRange r;
    r.lo = lo;
    r.hi = hi;
    vec_push(rs, r);
}

// Standard escape ranges added into a range list.
private void add_digit(Vec<RxRange>* rs) { class_add(rs, '0', '9'); }
private void add_word(Vec<RxRange>* rs) {
    class_add(rs, '0', '9');
    class_add(rs, 'A', 'Z');
    class_add(rs, 'a', 'z');
    class_add(rs, '_', '_');
}
private void add_space(Vec<RxRange>* rs) {
    class_add(rs, ' ', ' ');
    class_add(rs, '\t', '\t');
    class_add(rs, '\n', '\n');
    class_add(rs, '\r', '\r');
    class_add(rs, 11, 12);   // \v \f
}

// --- Unicode property escapes (\p{...} / \P{...}) --------------------------

// Appends the code-point ranges of one Unicode property to `rs`. Accepts a
// general category (short or long name, single category or group letter,
// optionally spelled `General_Category=Lu` / `gc=Lu`) and the supported
// binary properties. Returns false for anything else — including the
// deliberately unsupported `Script=` — so the caller can reject the pattern
// instead of silently matching something else.
private bool uniprop_ranges(Vec<RxRange>* rs, str name) {
    str n = name;
    // an explicit `lhs=rhs` form: only General_Category is supported
    i32 eq = -1;
    for i32 i = 0; i < n.len; i++ {
        if *(n.data + i) == '=' { eq = i; break; }
    }
    if eq >= 0 {
        str lhs;
        lhs.data = n.data;
        lhs.len = eq;
        n.data = n.data + eq + 1;
        n.len = n.len - eq - 1;
        if n.len == 0 { return false; }
        // Script= is a partition, walked like the category table.
        // Script_Extensions is multi-valued and deliberately unsupported.
        if str_equal(lhs, "Script") || str_equal(lhs, "sc") {
            i32 sid = uniprop_script_id(n);
            if sid < 0 { return false; }
            for i32 i = 0; i < UNI_SC_RUNS; i++ {
                if cast(i32, UNI_SC_ID[i]) != sid { continue; }
                i32 lo = cast(i32, UNI_SC_START[i]);
                i32 hi = 0x10FFFF;
                if i + 1 < UNI_SC_RUNS { hi = cast(i32, UNI_SC_START[i + 1]) - 1; }
                class_add(rs, lo, hi);
            }
            return true;
        }
        if !str_equal(lhs, "General_Category") && !str_equal(lhs, "gc") { return false; }
    }
    if n.len == 0 { return false; }

    u32 mask = uniprop_gc_mask(n);
    if mask != 0 {
        for i32 i = 0; i < UNI_GC_RUNS; i++ {
            u32 bit = cast(u32, 1) << UNI_GC_CAT[i];
            if (mask & bit) == 0 { continue; }
            i32 lo = cast(i32, UNI_GC_START[i]);
            i32 hi = 0x10FFFF;
            if i + 1 < UNI_GC_RUNS { hi = cast(i32, UNI_GC_START[i + 1]) - 1; }
            class_add(rs, lo, hi);
        }
        return true;
    }
    u32* tbl;
    i32 cnt;
    if uniprop_binary(n, &tbl, &cnt) {
        for i32 i = 0; i < cnt; i++ {
            class_add(rs, cast(i32, *(tbl + i * 2)), cast(i32, *(tbl + i * 2 + 1)));
        }
        return true;
    }
    return false;
}

// Complement of `src` over the whole code-point space. `src` must be in
// ascending order, which the generated tables and the run walk both are.
private void uniprop_complement(Vec<RxRange>* dst, Vec<RxRange>* src) {
    i32 next = 0;
    for i32 i = 0; i < src.len; i++ {
        RxRange r = vec_get(src, i);
        if r.lo > next { class_add(dst, next, r.lo - 1); }
        if r.hi + 1 > next { next = r.hi + 1; }
    }
    if next <= 0x10FFFF { class_add(dst, next, 0x10FFFF); }
}

// Parses `\p{Name}` / `\P{Name}` with p.pos on the `p`/`P`, appending the
// resulting ranges to `rs`. Returns false (and marks the pattern failed) for
// a malformed or unsupported property.
private bool parse_uniprop(RxParser* p, Vec<RxRange>* rs, bool negated) {
    p.pos++;                       // past p / P
    if px_cur(p) != '{' { p.failed = true; return false; }
    p.pos++;
    i32 start = p.pos;
    while p.pos < p.src.len && px_cur(p) != '}' { p.pos++; }
    if p.pos >= p.src.len { p.failed = true; return false; }
    str name;
    name.data = p.src.data + start;
    name.len = p.pos - start;
    p.pos++;                       // past }

    Vec<RxRange> tmp = vec_new<RxRange>(8);
    bool ok = uniprop_ranges(&tmp, name);
    if !ok {
        vec_free(&tmp);
        p.failed = true;
        return false;
    }
    if negated {
        uniprop_complement(rs, &tmp);
    } else {
        for i32 i = 0; i < tmp.len; i++ { vec_push(rs, vec_get(&tmp, i)); }
    }
    vec_free(&tmp);
    return true;
}

// Complement of [lo..hi] style set over 0..255 given the base ranges.
private void add_negated(Vec<RxRange>* dst, Vec<RxRange>* base) {
    // mark covered bytes, then emit gaps
    bool[256] covered;
    for i32 i = 0; i < 256; i++ { covered[i] = false; }
    for i32 i = 0; i < base.len; i++ {
        RxRange r = vec_get(base, i);
        for i32 b = r.lo; b <= r.hi && b < 256; b++ { covered[b] = true; }
    }
    i32 start = -1;
    for i32 b = 0; b < 256; b++ {
        if !covered[b] {
            if start < 0 { start = b; }
        } else {
            if start >= 0 { class_add(dst, start, b - 1); start = -1; }
        }
    }
    if start >= 0 { class_add(dst, start, 255); }
}

// Registers a class; returns its index.
private i32 register_class(RxParser* p, Vec<RxRange>* rs, bool negate) {
    RxClass c;
    c.n = rs.len;
    c.ranges = alloc<RxRange>(rs.len > 0 ? rs.len : 1);
    for i32 i = 0; i < rs.len; i++ {
        *(c.ranges + i) = vec_get(rs, i);
    }
    c.negate = negate;
    vec_push(&p.classes, c);
    return p.classes.len - 1;
}

private i32 hexval(u8 c) {
    if c >= '0' && c <= '9' { return c - '0'; }
    if c >= 'a' && c <= 'f' { return c - 'a' + 10; }
    if c >= 'A' && c <= 'F' { return c - 'A' + 10; }
    return -1;
}

// A single-char escape value, or -1 if the escape is a class/special.
private i32 escape_char(RxParser* p) {
    u8 c = px_cur(p);
    p.pos++;
    if c == 'n' { return '\n'; }
    if c == 't' { return '\t'; }
    if c == 'r' { return '\r'; }
    if c == 'f' { return 12; }
    if c == 'v' { return 11; }
    if c == '0' { return 0; }
    if c == 'x' {
        i32 h1 = hexval(px_cur(p));
        i32 h2 = hexval(px_at(p, p.pos + 1));
        if h1 >= 0 && h2 >= 0 {
            p.pos += 2;
            return h1 * 16 + h2;
        }
        return 'x';
    }
    if c == 'u' {
        if px_cur(p) == '{' {
            // \u{...} code-point escape (u mode)
            if !p.unicode { return 'u'; }
            p.pos++;   // '{'
            i32 cp = 0;
            i32 nd = 0;
            while px_cur(p) != '}' && px_cur(p) != 0 {
                i32 h = hexval(px_cur(p));
                if h < 0 { p.failed = true; return 'u'; }
                cp = cp * 16 + h;
                nd++;
                p.pos++;
            }
            if px_cur(p) == '}' && nd > 0 && cp <= 0x10FFFF { p.pos++; return cp; }
            p.failed = true;
            return 'u';
        }
        i32 h1 = hexval(px_cur(p));
        i32 h2 = hexval(px_at(p, p.pos + 1));
        i32 h3 = hexval(px_at(p, p.pos + 2));
        i32 h4 = hexval(px_at(p, p.pos + 3));
        if h1 >= 0 && h2 >= 0 && h3 >= 0 && h4 >= 0 {
            i32 cp = ((h1 * 16 + h2) * 16 + h3) * 16 + h4;
            p.pos += 4;
            // u mode: combine a surrogate pair into an astral code point
            if p.unicode && cp >= 0xD800 && cp <= 0xDBFF
                    && px_cur(p) == '\\' && px_at(p, p.pos + 1) == 'u' {
                i32 l1 = hexval(px_at(p, p.pos + 2));
                i32 l2 = hexval(px_at(p, p.pos + 3));
                i32 l3 = hexval(px_at(p, p.pos + 4));
                i32 l4 = hexval(px_at(p, p.pos + 5));
                if l1 >= 0 && l2 >= 0 && l3 >= 0 && l4 >= 0 {
                    i32 lo = ((l1 * 16 + l2) * 16 + l3) * 16 + l4;
                    if lo >= 0xDC00 && lo <= 0xDFFF {
                        p.pos += 6;
                        return 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                    }
                }
            }
            return cp;
        }
        return 'u';
    }
    return c;   // escaped literal (\. \* \\ etc.)
}

private RxNode* parse_class(RxParser* p) {
    p.pos++;   // '['
    bool negate = false;
    if px_cur(p) == '^' { negate = true; p.pos++; }
    Vec<RxRange> rs = vec_new<RxRange>(4);
    while p.pos < p.src.len && px_cur(p) != ']' {
        i32 lo;
        if px_cur(p) == '\\' {
            p.pos++;
            u8 e = px_cur(p);
            if e == 'd' { p.pos++; add_digit(&rs); continue; }
            if e == 'w' { p.pos++; add_word(&rs); continue; }
            if e == 's' { p.pos++; add_space(&rs); continue; }
            if e == 'D' {
                p.pos++;
                Vec<RxRange> base = vec_new<RxRange>(2);
                add_digit(&base);
                add_negated(&rs, &base);
                vec_free(&base);
                continue;
            }
            if e == 'W' {
                p.pos++;
                Vec<RxRange> base = vec_new<RxRange>(4);
                add_word(&base);
                add_negated(&rs, &base);
                vec_free(&base);
                continue;
            }
            if e == 'S' {
                p.pos++;
                Vec<RxRange> base = vec_new<RxRange>(6);
                add_space(&base);
                add_negated(&rs, &base);
                vec_free(&base);
                continue;
            }
            // \p{...} inside a class contributes its ranges as a class member;
            // \P{...} contributes the property's complement, which is not the
            // same as negating the enclosing class.
            if (e == 'p' || e == 'P') && p.unicode && px_at(p, p.pos + 1) == '{' {
                ignore parse_uniprop(p, &rs, e == 'P');
                continue;
            }
            lo = escape_char(p);
        } else {
            lo = px_read_cp(p);
        }
        // range a-b (but not if '-' is last before ']')
        if px_cur(p) == '-' && px_at(p, p.pos + 1) != ']' && p.pos + 1 < p.src.len {
            p.pos++;
            i32 hi;
            if px_cur(p) == '\\' {
                p.pos++;
                hi = escape_char(p);
            } else {
                hi = px_read_cp(p);
            }
            class_add(&rs, lo, hi);
        } else {
            class_add(&rs, lo, lo);
        }
    }
    if px_cur(p) == ']' { p.pos++; } else { p.failed = true; }
    i32 ci = register_class(p, &rs, negate);
    vec_free(&rs);
    RxNode* n = rx_node(RN_CLASS);
    n.cls = ci;
    return n;
}

private i32 parse_int(RxParser* p) {
    i32 v = 0;
    bool any = false;
    while px_cur(p) >= '0' && px_cur(p) <= '9' {
        i32 d = px_cur(p);
        v = v * 10 + (d - '0');
        p.pos++;
        any = true;
    }
    if !any { return -1; }
    return v;
}

private RxNode* parse_atom(RxParser* p, Vec<RxNodePtr>* stack) {
    u8 c = px_cur(p);
    if c == '(' {
        p.pos++;
        i32 kind = RN_GROUP;
        i32 gidx = 0;
        bool neg_look = false;
        if px_cur(p) == '?' {
            p.pos++;
            u8 m = px_cur(p);
            if m == ':' { p.pos++; kind = RN_NCGROUP; }
            else if m == '=' { p.pos++; kind = RN_LOOK; neg_look = false; }
            else if m == '!' { p.pos++; kind = RN_LOOK; neg_look = true; }
            else if m == '<' && px_at(p, p.pos + 1) == '=' {
                p.pos += 2; kind = RN_LOOKBEHIND; neg_look = false;
            }
            else if m == '<' && px_at(p, p.pos + 1) == '!' {
                p.pos += 2; kind = RN_LOOKBEHIND; neg_look = true;
            }
            else if m == '<' && px_at(p, p.pos + 1) != '=' && px_at(p, p.pos + 1) != '!' {
                // named capturing group (?<name>...)
                p.pos++;   // consume '<'
                i32 nstart = p.pos;
                while px_cur(p) != '>' && px_cur(p) != 0 { p.pos++; }
                str nm;
                nm.data = p.src.data + nstart;
                nm.len = p.pos - nstart;
                if px_cur(p) == '>' { p.pos++; } else { p.failed = true; }
                p.group_count++;
                gidx = p.group_count;
                RxGroupName gn;
                gn.idx = gidx;
                gn.name = nm;
                vec_push(&p.gnames, gn);
            }
            else { p.failed = true; kind = RN_NCGROUP; }
        } else {
            p.group_count++;
            gidx = p.group_count;
        }
        RxNode* inner = parse_alt(p, stack);
        if px_cur(p) == ')' { p.pos++; } else { p.failed = true; }
        RxNode* g = rx_node(kind);
        g.child = inner;
        if kind == RN_GROUP { g.a = gidx; }
        if kind == RN_LOOK { g.a = neg_look ? 1 : 0; }
        if kind == RN_LOOKBEHIND { g.a = neg_look ? 1 : 0; }
        return g;
    }
    if c == '[' { return parse_class(p); }
    if c == '.' { p.pos++; return rx_node(RN_ANY); }
    if c == '^' { p.pos++; return rx_node(RN_BOL); }
    if c == '$' { p.pos++; return rx_node(RN_EOL); }
    if c == '\\' {
        p.pos++;
        u8 e = px_cur(p);
        if e == 'b' { p.pos++; return rx_node(RN_WORDB); }
        if e == 'B' { p.pos++; return rx_node(RN_NWORDB); }
        if e == 'd' || e == 'w' || e == 's' || e == 'D' || e == 'W' || e == 'S' {
            p.pos++;
            Vec<RxRange> rs = vec_new<RxRange>(4);
            bool neg = false;
            if e == 'd' { add_digit(&rs); }
            if e == 'w' { add_word(&rs); }
            if e == 's' { add_space(&rs); }
            if e == 'D' { add_digit(&rs); neg = true; }
            if e == 'W' { add_word(&rs); neg = true; }
            if e == 'S' { add_space(&rs); neg = true; }
            i32 ci = register_class(p, &rs, neg);
            vec_free(&rs);
            RxNode* n = rx_node(RN_CLASS);
            n.cls = ci;
            return n;
        }
        if e >= '1' && e <= '9' {
            i32 g = parse_int(p);
            RxNode* n = rx_node(RN_BACKREF);
            n.a = g;
            return n;
        }
        if e == 'k' && px_at(p, p.pos + 1) == '<' {
            i32 nstart = p.pos + 2;
            i32 nend = nstart;
            while nend < p.src.len && *(p.src.data + nend) != cast(u8, '>') { nend++; }
            // Under /u, and in any pattern that declares a named group, this is
            // a backreference and an unknown name is a SyntaxError. Only a
            // non-unicode pattern with no named group at all keeps the Annex B
            // reading, where `\k` is an identity escape and the rest is literal.
            bool is_ref = p.unicode || p.declared.len > 0;
            if is_ref && nend < p.src.len {
                p.pos = nend + 1;
                RxNode* n = rx_node(RN_BACKREF);
                n.a = -1;
                n.b = nstart;
                n.c = nend - nstart;
                vec_push(&p.kpend, n);
                return n;
            }
        }
        if (e == 'p' || e == 'P') && p.unicode && px_at(p, p.pos + 1) == '{' {
            Vec<RxRange> rs = vec_new<RxRange>(8);
            bool ok = parse_uniprop(p, &rs, e == 'P');
            i32 ci = register_class(p, &rs, false);
            vec_free(&rs);
            if !ok { return rx_node(RN_CHAR); }
            RxNode* n = rx_node(RN_CLASS);
            n.cls = ci;
            return n;
        }
        i32 ch = escape_char(p);
        return cp_to_node(ch);
    }
    // literal: a whole code point in u mode, else a single byte
    if p.unicode && c >= 0x80 {
        return cp_to_node(px_read_cp(p));
    }
    p.pos++;
    RxNode* n = rx_node(RN_CHAR);
    n.a = c;
    return n;
}

private RxNode* parse_quant(RxParser* p, Vec<RxNodePtr>* stack) {
    RxNode* atom = parse_atom(p, stack);
    u8 c = px_cur(p);
    i32 kind = -1;
    i32 rmin = 0;
    i32 rmax = 0;
    if c == '*' { kind = RN_STAR; p.pos++; }
    else if c == '+' { kind = RN_PLUS; p.pos++; }
    else if c == '?' { kind = RN_QUEST; p.pos++; }
    else if c == '{' {
        i32 save = p.pos;
        p.pos++;
        rmin = parse_int(p);
        if rmin < 0 { p.pos = save; return atom; }
        rmax = rmin;
        if px_cur(p) == ',' {
            p.pos++;
            if px_cur(p) == '}' {
                rmax = -1;
            } else {
                rmax = parse_int(p);
                if rmax < 0 { p.pos = save; return atom; }
            }
        }
        if px_cur(p) == '}' { p.pos++; } else { p.pos = save; return atom; }
        kind = RN_REPEAT;
    }
    if kind < 0 { return atom; }
    bool greedy = true;
    if px_cur(p) == '?' { greedy = false; p.pos++; }
    RxNode* q = rx_node(kind);
    q.child = atom;
    q.a = greedy ? 1 : 0;
    if kind == RN_REPEAT {
        q.a = rmin;
        q.b = rmax;
        q.c = greedy ? 1 : 0;
    }
    return q;
}

private RxNode* parse_concat(RxParser* p, Vec<RxNodePtr>* stack) {
    i32 base_i = stack.len;
    while p.pos < p.src.len && px_cur(p) != '|' && px_cur(p) != ')' {
        i32 before = p.pos;
        vec_push(stack, parse_quant(p, stack));
        if p.pos == before { p.failed = true; break; }
    }
    if stack.len - base_i == 1 {
        RxNode* only = vec_get(stack, base_i);
        stack.len = base_i;
        return only;
    }
    return rx_kids(RN_CONCAT, stack, base_i);
}

private RxNode* parse_alt(RxParser* p, Vec<RxNodePtr>* stack) {
    i32 base_i = stack.len;
    vec_push(stack, parse_concat(p, stack));
    while px_cur(p) == '|' {
        p.pos++;
        vec_push(stack, parse_concat(p, stack));
    }
    if stack.len - base_i == 1 {
        RxNode* only = vec_get(stack, base_i);
        stack.len = base_i;
        return only;
    }
    return rx_kids(RN_ALT, stack, base_i);
}

private void free_node(RxNode* n) {
    if n == null { return; }
    free_node(n.child);
    for i32 i = 0; i < n.nkids; i++ {
        free_node(*(n.kids + i));
    }
    if n.kids != null { free(n.kids); }
    free(n);
}

// --- emit -----------------------------------------------------------------

private i32 emit(Vec<RxInst>* code, i32 op, i32 x, i32 y, i32 cls) {
    RxInst i;
    i.op = op;
    i.x = x;
    i.y = y;
    i.cls = cls;
    vec_push(code, i);
    return code.len - 1;
}

private void patch_x(Vec<RxInst>* code, i32 at, i32 v) { (code.data + at).x = v; }
private void patch_y(Vec<RxInst>* code, i32 at, i32 v) { (code.data + at).y = v; }

private void emit_quant_child(Vec<RxInst>* code, RxNode* child, i32 kind, bool greedy) {
    if kind == RN_STAR {
        i32 l1 = emit(code, I_SPLIT, 0, 0, 0);
        i32 body = code.len;
        emit_node(code, child);
        emit(code, I_JMP, l1, 0, 0);
        i32 after = code.len;
        if greedy { patch_x(code, l1, body); patch_y(code, l1, after); }
        else { patch_x(code, l1, after); patch_y(code, l1, body); }
        return;
    }
    if kind == RN_PLUS {
        i32 l1 = code.len;
        emit_node(code, child);
        i32 sp = emit(code, I_SPLIT, 0, 0, 0);
        i32 after = code.len;
        if greedy { patch_x(code, sp, l1); patch_y(code, sp, after); }
        else { patch_x(code, sp, after); patch_y(code, sp, l1); }
        return;
    }
    if kind == RN_QUEST {
        i32 sp = emit(code, I_SPLIT, 0, 0, 0);
        i32 body = code.len;
        emit_node(code, child);
        i32 after = code.len;
        if greedy { patch_x(code, sp, body); patch_y(code, sp, after); }
        else { patch_x(code, sp, after); patch_y(code, sp, body); }
        return;
    }
}

// Maximum byte length a node can match; -1 if unbounded. Used to bound
// the lookbehind scan.
private i32 rx_max_len(RxNode* n) {
    if n == null { return 0; }
    i32 k = n.kind;
    if k == RN_CHAR || k == RN_ANY || k == RN_CLASS { return 1; }
    if k == RN_CONCAT {
        i32 sum = 0;
        for i32 i = 0; i < n.nkids; i++ {
            i32 c = rx_max_len(*(n.kids + i));
            if c < 0 { return -1; }
            sum += c;
        }
        return sum;
    }
    if k == RN_ALT {
        i32 mx = 0;
        for i32 i = 0; i < n.nkids; i++ {
            i32 c = rx_max_len(*(n.kids + i));
            if c < 0 { return -1; }
            if c > mx { mx = c; }
        }
        return mx;
    }
    if k == RN_QUEST { return rx_max_len(n.child); }
    if k == RN_REPEAT {
        if n.b < 0 { return -1; }   // unbounded upper
        i32 c = rx_max_len(n.child);
        if c < 0 { return -1; }
        return c * n.b;
    }
    if k == RN_GROUP || k == RN_NCGROUP { return rx_max_len(n.child); }
    if k == RN_STAR || k == RN_PLUS || k == RN_BACKREF { return -1; }
    // RN_EMPTY and the zero-width anchors/lookarounds
    return 0;
}

private void emit_node(Vec<RxInst>* code, RxNode* n) {
    i32 k = n.kind;
    if k == RN_EMPTY { return; }
    if k == RN_CHAR { emit(code, I_CHAR, n.a, 0, 0); return; }
    if k == RN_ANY { emit(code, I_ANY, 0, 0, 0); return; }
    if k == RN_CLASS { emit(code, I_CLASS, 0, 0, n.cls); return; }
    if k == RN_BOL { emit(code, I_BOL, 0, 0, 0); return; }
    if k == RN_EOL { emit(code, I_EOL, 0, 0, 0); return; }
    if k == RN_WORDB { emit(code, I_WORDB, 0, 0, 0); return; }
    if k == RN_NWORDB { emit(code, I_NWORDB, 0, 0, 0); return; }
    if k == RN_BACKREF { emit(code, I_BACKREF, n.a, 0, 0); return; }
    if k == RN_CONCAT {
        for i32 i = 0; i < n.nkids; i++ { emit_node(code, *(n.kids + i)); }
        return;
    }
    if k == RN_ALT {
        Vec<i32> jmps = vec_new<i32>(4);
        for i32 i = 0; i < n.nkids; i++ {
            if i < n.nkids - 1 {
                i32 sp = emit(code, I_SPLIT, 0, 0, 0);
                patch_x(code, sp, code.len);
                emit_node(code, *(n.kids + i));
                vec_push(&jmps, emit(code, I_JMP, 0, 0, 0));
                patch_y(code, sp, code.len);
            } else {
                emit_node(code, *(n.kids + i));
            }
        }
        i32 end = code.len;
        for i32 i = 0; i < jmps.len; i++ {
            patch_x(code, vec_get(&jmps, i), end);
        }
        vec_free(&jmps);
        return;
    }
    if k == RN_STAR || k == RN_PLUS || k == RN_QUEST {
        emit_quant_child(code, n.child, k, n.a != 0);
        return;
    }
    if k == RN_REPEAT {
        bool greedy = n.c != 0;
        for i32 i = 0; i < n.a; i++ { emit_node(code, n.child); }
        if n.b < 0 {
            emit_quant_child(code, n.child, RN_STAR, greedy);
        } else {
            for i32 i = n.a; i < n.b; i++ {
                emit_quant_child(code, n.child, RN_QUEST, greedy);
            }
        }
        return;
    }
    if k == RN_GROUP {
        emit(code, I_SAVE, 2 * n.a, 0, 0);
        emit_node(code, n.child);
        emit(code, I_SAVE, 2 * n.a + 1, 0, 0);
        return;
    }
    if k == RN_NCGROUP {
        emit_node(code, n.child);
        return;
    }
    if k == RN_LOOK {
        i32 b = emit(code, I_LOOK_BEGIN, n.a, 0, 0);
        emit_node(code, n.child);
        emit(code, I_LOOK_DONE, 0, 0, 0);
        patch_y(code, b, code.len);
        return;
    }
    if k == RN_LOOKBEHIND {
        // cls carries the child's max byte length (-1 unbounded) so the
        // matcher only scans back that far for a candidate start.
        i32 b = emit(code, I_BEHIND_BEGIN, n.a, 0, rx_max_len(n.child));
        emit_node(code, n.child);
        emit(code, I_BEHIND_DONE, 0, 0, 0);
        patch_y(code, b, code.len);
        return;
    }
}

// --- compile --------------------------------------------------------------

// Returns null on parse error.
// Collects the names of every (?<name>) group, skipping character classes and
// escapes so a "(?<" inside one is not mistaken for a group. Lookbehind
// ((?<= and (?<!) is not a named group.
private void scan_group_names(str pat, Vec<str>* out) {
    bool in_class = false;
    i32 i = 0;
    while i < pat.len {
        u8 c = *(pat.data + i);
        if c == cast(u8, 92) { i += 2; continue; }   // backslash
        if in_class {
            if c == cast(u8, ']') { in_class = false; }
            i++;
            continue;
        }
        if c == cast(u8, '[') { in_class = true; i++; continue; }
        if c == cast(u8, '(') && i + 2 < pat.len
            && *(pat.data + i + 1) == cast(u8, '?') && *(pat.data + i + 2) == cast(u8, '<') {
            u8 d = i + 3 < pat.len ? *(pat.data + i + 3) : 0;
            if d != cast(u8, '=') && d != cast(u8, '!') {
                i32 s = i + 3;
                i32 e = s;
                while e < pat.len && *(pat.data + e) != cast(u8, '>') { e++; }
                str nm;
                nm.data = pat.data + s;
                nm.len = e - s;
                vec_push(out, nm);
                i = e;
                continue;
            }
        }
        i++;
    }
}

// The flag set is exactly "dgimsuvy", each at most once.
bool regex_flags_valid(str flags) {
    i32 seen = 0;
    for i32 i = 0; i < flags.len; i++ {
        u8 c = *(flags.data + i);
        i32 bit = 0;
        if c == cast(u8, 'd') { bit = 1; }
        else if c == cast(u8, 'g') { bit = 2; }
        else if c == cast(u8, 'i') { bit = 4; }
        else if c == cast(u8, 'm') { bit = 8; }
        else if c == cast(u8, 's') { bit = 16; }
        else if c == cast(u8, 'u') { bit = 32; }
        else if c == cast(u8, 'v') { bit = 64; }
        else if c == cast(u8, 'y') { bit = 128; }
        else { return false; }
        if (seen & bit) != 0 { return false; }
        seen = seen | bit;
    }
    return true;
}

RegexProg* regex_compile(str pattern, str flags) {
    RxParser p;
    p.src = pattern;
    p.pos = 0;
    p.group_count = 0;
    p.failed = false;
    p.unicode = false;
    for i32 i = 0; i < flags.len; i++ {
        if *(flags.data + i) == 'u' { p.unicode = true; }
    }
    vec_init<RxClass>(&p.classes, 4);
    vec_init<RxGroupName>(&p.gnames, 2);
    vec_init<RxNodePtr>(&p.kpend, 2);
    vec_init<str>(&p.declared, 2);
    scan_group_names(pattern, &p.declared);
    Vec<RxNodePtr> stack = vec_new<RxNodePtr>(8);
    RxNode* root = parse_alt(&p, &stack);
    vec_free(&stack);
    // Resolve \k<name> now that every named group has been seen, so a
    // reference may point forward as well as back.
    for i32 i = 0; i < p.kpend.len; i++ {
        RxNode* kn = vec_get(&p.kpend, i);
        str want;
        want.data = p.src.data + kn.b;
        want.len = kn.c;
        bool found = false;
        for i32 j = 0; j < p.gnames.len; j++ {
            RxGroupName gn = vec_get(&p.gnames, j);
            if str_equal(gn.name, want) { kn.a = gn.idx; found = true; break; }
        }
        if !found { p.failed = true; }
    }
    vec_free(&p.kpend);
    vec_free(&p.declared);
    if p.failed || p.pos != pattern.len {
        free_node(root);
        for i32 i = 0; i < p.classes.len; i++ {
            free(vec_get(&p.classes, i).ranges);
        }
        vec_free(&p.classes);
        vec_free(&p.gnames);
        return null;
    }

    Vec<RxInst> code = vec_new<RxInst>(32);
    emit(&code, I_SAVE, 0, 0, 0);
    emit_node(&code, root);
    emit(&code, I_SAVE, 1, 0, 0);
    emit(&code, I_MATCH, 0, 0, 0);
    free_node(root);

    RegexProg* prog = new(RegexProg);
    prog.code_len = code.len;
    prog.code = alloc<RxInst>(code.len);
    for i32 i = 0; i < code.len; i++ {
        *(prog.code + i) = vec_get(&code, i);
    }
    vec_free(&code);
    prog.n_groups = p.group_count;

    // group names: index 1..n_groups -> name (empty if unnamed)
    i32 gn_size = p.group_count + 1;
    prog.group_names = alloc<str>(gn_size);
    for i32 i = 0; i < gn_size; i++ {
        str empty;
        empty.data = null;
        empty.len = 0;
        *(prog.group_names + i) = empty;
    }
    prog.has_named = p.gnames.len > 0;
    for i32 i = 0; i < p.gnames.len; i++ {
        RxGroupName gn = vec_get(&p.gnames, i);
        if gn.idx >= 1 && gn.idx <= p.group_count && gn.name.len > 0 {
            // own a copy: the parser's views point into the pattern source
            u8* buf = alloc<u8>(gn.name.len);
            memcpy(buf, gn.name.data, gn.name.len);
            str owned;
            owned.data = buf;
            owned.len = gn.name.len;
            *(prog.group_names + gn.idx) = owned;
        }
    }
    vec_free(&p.gnames);

    // pack classes
    prog.n_classes = p.classes.len;
    i32 total = 0;
    for i32 i = 0; i < p.classes.len; i++ { total += vec_get(&p.classes, i).n; }
    prog.class_ranges = alloc<RxRange>(total > 0 ? total : 1);
    prog.class_off = alloc<i32>(p.classes.len > 0 ? p.classes.len : 1);
    prog.class_len = alloc<i32>(p.classes.len > 0 ? p.classes.len : 1);
    prog.class_neg = alloc<bool>(p.classes.len > 0 ? p.classes.len : 1);
    i32 off = 0;
    for i32 i = 0; i < p.classes.len; i++ {
        RxClass c = vec_get(&p.classes, i);
        *(prog.class_off + i) = off;
        *(prog.class_len + i) = c.n;
        *(prog.class_neg + i) = c.negate;
        for i32 j = 0; j < c.n; j++ {
            *(prog.class_ranges + off) = *(c.ranges + j);
            off++;
        }
        free(c.ranges);
    }
    vec_free(&p.classes);

    prog.ignore_case = false;
    prog.multiline = false;
    prog.dotall = false;
    prog.global = false;
    prog.sticky = false;
    prog.unicode = false;
    for i32 i = 0; i < flags.len; i++ {
        u8 f = *(flags.data + i);
        if f == 'i' { prog.ignore_case = true; }
        if f == 'm' { prog.multiline = true; }
        if f == 's' { prog.dotall = true; }
        if f == 'g' { prog.global = true; }
        if f == 'y' { prog.sticky = true; }
        if f == 'u' { prog.unicode = true; }
    }
    return prog;
}

void regex_free(RegexProg* prog) {
    if prog == null { return; }
    free(prog.code);
    free(prog.class_ranges);
    free(prog.class_off);
    free(prog.class_len);
    free(prog.class_neg);
    if prog.group_names != null {
        for i32 i = 0; i <= prog.n_groups; i++ {
            str nm = *(prog.group_names + i);
            if nm.data != null { free(nm.data); }
        }
        free(prog.group_names);
    }
    free(prog);
}

i32 regex_ngroups(RegexProg* prog) { return prog.n_groups; }
bool regex_is_global(RegexProg* prog) { return prog.global; }
bool regex_is_sticky(RegexProg* prog) { return prog.sticky; }
bool regex_has_named(RegexProg* prog) { return prog.has_named; }
str regex_group_name(RegexProg* prog, i32 gidx) {
    if gidx < 0 || gidx > prog.n_groups { str e; e.data = null; e.len = 0; return e; }
    return *(prog.group_names + gidx);
}
// Group index for a name, or -1 if none.
i32 regex_group_index(RegexProg* prog, str name) {
    if !prog.has_named { return -1; }
    for i32 g = 1; g <= prog.n_groups; g++ {
        str nm = *(prog.group_names + g);
        if nm.len == name.len && nm.len > 0 && str_equal(nm, name) { return g; }
    }
    return -1;
}

// --- matcher --------------------------------------------------------------

struct RxCtx {
    RegexProg* prog;
    u8* s;
    i32 len;
    i32* caps;
    i32 steps;
    i32 look_end;   // target end position for the active lookbehind
}

const i32 RX_STEP_LIMIT = 2000000;

private u8 fold(u8 c) {
    if c >= 'A' && c <= 'Z' { return cast(u8, c + 32); }
    return c;
}

private bool byte_eq(RxCtx* cx, u8 a, u8 b) {
    if a == b { return true; }
    if cx.prog.ignore_case { return fold(a) == fold(b); }
    return false;
}

private bool in_class_raw(RxCtx* cx, i32 cls, i32 cp) {
    i32 off = *(cx.prog.class_off + cls);
    i32 n = *(cx.prog.class_len + cls);
    for i32 i = 0; i < n; i++ {
        RxRange r = *(cx.prog.class_ranges + off + i);
        if cp >= r.lo && cp <= r.hi { return true; }
    }
    return false;
}

private bool class_match(RxCtx* cx, i32 cls, i32 cp) {
    bool hit = in_class_raw(cx, cls, cp);
    if !hit && cx.prog.ignore_case {
        i32 alt = cp;
        if cp >= 'a' && cp <= 'z' { alt = cp - 32; }
        else if cp >= 'A' && cp <= 'Z' { alt = cp + 32; }
        if alt != cp { hit = in_class_raw(cx, cls, alt); }
    }
    if *(cx.prog.class_neg + cls) { return !hit; }
    return hit;
}

private bool is_word_byte(u8 c) {
    return (c >= '0' && c <= '9') || (c >= 'A' && c <= 'Z')
        || (c >= 'a' && c <= 'z') || c == '_';
}

private bool at_boundary(RxCtx* cx, i32 sp) {
    bool before = sp > 0 && is_word_byte(*(cx.s + sp - 1));
    bool after = sp < cx.len && is_word_byte(*(cx.s + sp));
    return before != after;
}

// Returns the end position, or -1 on failure.
private i32 m(RxCtx* cx, i32 pc, i32 sp) {
    while true {
        cx.steps++;
        if cx.steps > RX_STEP_LIMIT { return -1; }
        RxInst* inst = cx.prog.code + pc;
        i32 op = inst.op;
        if op == I_CHAR {
            if sp < cx.len && byte_eq(cx, *(cx.s + sp), cast(u8, inst.x)) {
                pc++;
                sp++;
                continue;
            }
            return -1;
        }
        if op == I_ANY {
            if sp < cx.len {
                u8 c = *(cx.s + sp);
                if cx.prog.dotall || (c != '\n' && c != '\r') {
                    pc++;
                    // u mode: `.` consumes a whole code point
                    if cx.prog.unicode && c >= 0x80 {
                        i32 sl = utf8_seq_len(c);
                        if sp + sl <= cx.len { sp += sl; } else { sp++; }
                    } else {
                        sp++;
                    }
                    continue;
                }
            }
            return -1;
        }
        if op == I_CLASS {
            if sp < cx.len {
                u8 c = *(cx.s + sp);
                if cx.prog.unicode && c >= 0x80 {
                    // u mode: decode and test a full code point
                    i32 sl = utf8_seq_len(c);
                    i32 cp = c;
                    if sl == 2 && sp + 1 < cx.len {
                        cp = ((c & 0x1F) << 6) | (*(cx.s + sp + 1) & 0x3F);
                    } else if sl == 3 && sp + 2 < cx.len {
                        cp = ((c & 0x0F) << 12) | ((*(cx.s + sp + 1) & 0x3F) << 6) | (*(cx.s + sp + 2) & 0x3F);
                    } else if sl == 4 && sp + 3 < cx.len {
                        cp = ((c & 0x07) << 18) | ((*(cx.s + sp + 1) & 0x3F) << 12) | ((*(cx.s + sp + 2) & 0x3F) << 6) | (*(cx.s + sp + 3) & 0x3F);
                    }
                    if class_match(cx, inst.cls, cp) {
                        pc++;
                        sp += sl;
                        continue;
                    }
                    return -1;
                }
                if class_match(cx, inst.cls, cast(i32, c)) {
                    pc++;
                    sp++;
                    continue;
                }
            }
            return -1;
        }
        if op == I_MATCH { return sp; }
        if op == I_LOOK_DONE { return sp; }
        if op == I_BEHIND_DONE {
            // the lookbehind body must end exactly at the anchor position
            if sp == cx.look_end { return sp; }
            return -1;
        }
        if op == I_JMP { pc = inst.x; continue; }
        if op == I_SPLIT {
            i32 r = m(cx, inst.x, sp);
            if r >= 0 { return r; }
            pc = inst.y;
            continue;
        }
        if op == I_SAVE {
            i32 slot = inst.x;
            i32 old = *(cx.caps + slot);
            *(cx.caps + slot) = sp;
            i32 r = m(cx, pc + 1, sp);
            if r >= 0 { return r; }
            *(cx.caps + slot) = old;
            return -1;
        }
        if op == I_BOL {
            if sp == 0 || (cx.prog.multiline && *(cx.s + sp - 1) == '\n') {
                pc++;
                continue;
            }
            return -1;
        }
        if op == I_EOL {
            if sp == cx.len || (cx.prog.multiline && *(cx.s + sp) == '\n') {
                pc++;
                continue;
            }
            return -1;
        }
        if op == I_WORDB {
            if at_boundary(cx, sp) { pc++; continue; }
            return -1;
        }
        if op == I_NWORDB {
            if !at_boundary(cx, sp) { pc++; continue; }
            return -1;
        }
        if op == I_BACKREF {
            i32 g = inst.x;
            i32 gs = *(cx.caps + 2 * g);
            i32 ge = *(cx.caps + 2 * g + 1);
            if gs < 0 || ge < 0 { pc++; continue; }
            i32 glen = ge - gs;
            if sp + glen > cx.len { return -1; }
            for i32 k = 0; k < glen; k++ {
                if !byte_eq(cx, *(cx.s + sp + k), *(cx.s + gs + k)) { return -1; }
            }
            sp += glen;
            pc++;
            continue;
        }
        if op == I_LOOK_BEGIN {
            i32 r = m(cx, pc + 1, sp);
            bool ok = r >= 0;
            if inst.x != 0 { ok = !ok; }   // negate
            if ok { pc = inst.y; continue; }
            return -1;
        }
        if op == I_BEHIND_BEGIN {
            // succeeds if the body matches some span ending at sp; scan
            // candidate starts back to sp - maxlen (or 0 if unbounded)
            i32 target = sp;
            i32 lo = 0;
            if inst.cls >= 0 && target - inst.cls > 0 { lo = target - inst.cls; }
            i32 saved = cx.look_end;
            cx.look_end = target;
            bool matched = false;
            // longest span first (earliest start) = greedy right-to-left
            for i32 s = lo; s <= target; s++ {
                if m(cx, pc + 1, s) >= 0 { matched = true; break; }
            }
            cx.look_end = saved;
            bool ok = matched;
            if inst.x != 0 { ok = !ok; }   // negate
            if ok { pc = inst.y; continue; }
            return -1;
        }
        return -1;
    }
    return -1;
}

// caps must hold 2*(n_groups+1) i32s. Returns true on match; fills
// caps with start/end byte offsets per group (-1 when unset).
bool regex_exec(RegexProg* prog, str subject, i32 start, i32* caps) {
    i32 ncap = 2 * (prog.n_groups + 1);
    RxCtx cx;
    cx.prog = prog;
    cx.s = subject.data;
    cx.len = subject.len;
    cx.caps = caps;
    cx.look_end = -1;
    i32 base_i = start;
    if base_i < 0 { base_i = 0; }
    i32 last = subject.len;
    i32 i = base_i;
    while i <= last {
        for i32 j = 0; j < ncap; j++ { *(caps + j) = -1; }
        cx.steps = 0;
        i32 r = m(&cx, 0, i);
        if r >= 0 { return true; }
        if prog.sticky { return false; }
        // u mode: only attempt at code-point boundaries
        if prog.unicode && i < last {
            i += utf8_seq_len(*(subject.data + i));
        } else {
            i++;
        }
    }
    return false;
}
